package dev.re4bridge;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.mojang.blaze3d.platform.InputConstants;
import com.mojang.blaze3d.platform.NativeImage;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.CameraType;
import net.minecraft.client.GraphicsStatus;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.util.Mth;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.InteractionResult;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.projectile.AbstractArrow;
import net.minecraft.world.item.CrossbowItem;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.HitResult;
import org.lwjgl.glfw.GLFW;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Bridge between Minecraft and the RE4 REFramework scripts, through JSON files in RE4's
 * reframework\data folder:
 * - minecraft_bridge.json (written here, every tick): HUD state, movement, attacks, looked-at block.
 * - minecraft_blocks.json (written here, when blocks change): blocks around the player and their colors.
 * - minecraft_textures.json (written here, when new items show up): item textures for the HUD.
 * - minecraft_bridge_input.json (written by RE4): keys, look direction, hotbar slot, clicks.
 * - minecraft_bridge_sync.json (written by RE4): where Leon is, to keep both players lined up.
 * - minecraft_overlay.bin (written here, every frame): Minecraft's hand, item and HUD for the RE4 plugin.
 * - minecraft_overlay_plugin.json (written by the RE4 plugin): RE4's screen size.
 * - minecraft_terrain.json (written by RE4): RE4's ground and walls around Leon, which Minecraft's player
 *   walks on (Re4Terrain), and requests for a new anchor between the two worlds.
 * Minecraft's own code does movement, attacks, placing and breaking; RE4 shows the results.
 */
public class Re4Bridge implements ClientModInitializer {
    public static final Logger LOGGER = LoggerFactory.getLogger("re4bridge");

    private static final String DEFAULT_OUTPUT =
            "D:\\SteamLibrary\\steamapps\\common\\RESIDENT EVIL 4  BIOHAZARD RE4\\reframework\\data\\minecraft_bridge.json";

    // RE4 sends a heartbeat several times per second; without one for this long, the keyboard takes over again
    private static final long REMOTE_TIMEOUT_MS = 1500;
    private static final int BLOCK_SCAN_RADIUS = 12;
    private static final int BLOCK_SCAN_HEIGHT = 16;
    private static final int BLOCK_SCAN_EVERY_TICKS = 5;
    // Leon and the Minecraft player may drift apart this far (RE4 walls) before Minecraft's player is moved back
    private static final double SYNC_DISTANCE = 1.0;
    // Farther than this is not drift but RE4 loading another area; never teleport that far (it can freeze Minecraft)
    private static final double SYNC_MAX_DISTANCE = 8.0;

    private static Path outputFile;
    private static Path inputFile;
    private static Path syncFile;
    private static Path blocksFile;
    private static Path texturesFile;
    private static long seq = 0;
    private static long ticks = 0;
    private static boolean warnedWrite = false;

    private static long lastInputSeq = -1;
    private static long lastInputTime = 0;
    private static int lastInputSelected = -1;
    private static int lastInputSwings = -1;
    private static int lastInputUses = -1;
    private static int lastInputPerspective = -1;

    // Brightness of Minecraft's mobs and character in RE4 (RE4's scenes are darker than Minecraft's sky)
    private static volatile float characterBrightness = 0.7F;

    public static float characterBrightness() {
        return characterBrightness;
    }

    public static boolean re4Turn() {
        return re4Turn;
    }

    /** RE4's screen width in pixels (from the overlay plugin), or 0 when unknown. */
    public static int re4ScreenWidth() {
        return re4ScreenWidth;
    }

    private static volatile int re4ScreenWidth = 0;

    // Written by the renderer mixins, sent to RE4 so its camera matches Minecraft's
    public static volatile double worldFov = 70.0;
    public static volatile float cameraDistance = 4.0F;
    private static RemoteKeys keys = null;
    private static Float remoteYaw = null;
    private static Float remotePitch = null;
    private static boolean destroying = false;
    private static long lastSyncSeq = -1;

    private static double flatY = Double.NaN;
    private static long attackSeq = 0;
    private static float lastAttackDamage = 0;
    private static float lastAttackStrength = 0;
    private static boolean lastAttackCrit = false;

    private static String lastBlocksJson = "";
    private static long blocksVersion = 0;
    private static final Map<String, String> blockColors = new HashMap<>();
    private static final Map<String, String> itemTextures = new HashMap<>();
    private static long texturesVersion = 0;
    private static JsonObject guiImages = null;

    // Overlay mode: while RE4 is in control, Minecraft draws only its hand, item and HUD for RE4
    private static boolean overlayActive = false;
    private static GraphicsStatus savedGraphics = null;
    private static Integer savedGuiScale = null;
    private static Integer savedFramerate = null;
    private static final int OVERLAY_FPS = 60;
    private static Path pluginStatusFile;
    private static Path terrainFile;
    private static long lastTerrainSeq = -1;
    // RE4's turn (cutscene, grab, menu, F7): Minecraft's picture is hidden and RE4 gets the mouse
    private static volatile boolean re4Turn = false;
    // RE4 moves Leon (ladder, boat): RE4 gets the movement keys, Minecraft keeps the mouse and picture
    private static volatile boolean re4Keys = false;
    private static boolean useHeldByRe4 = false;
    // Position syncs: RE4 asked to move the player to where Leon ended up after one of RE4's actions
    private static long syncDone = 0;
    // Arrows the player shot (bows, crossbows, tridents), for RE4 to apply the damage
    private static int shotSeq = 0;
    private static int lastShotDamage = 0;
    private static boolean lastShotCrit = false;
    private static final java.util.LinkedHashSet<Integer> seenArrows = new java.util.LinkedHashSet<>();
    // Minecraft's player is moved this high when anchored, above anything in its own world
    private static final double ANCHOR_Y = 250.0;

    // Minecraft's own HUD images (1.21 sprite names) and its pixel font, so RE4 can draw the exact same UI
    private static final String[] GUI_IMAGES = {
            "gui/sprites/hud/hotbar", "gui/sprites/hud/hotbar_selection",
            "gui/sprites/hud/heart/container", "gui/sprites/hud/heart/full", "gui/sprites/hud/heart/half",
            "gui/sprites/hud/food_empty", "gui/sprites/hud/food_full", "gui/sprites/hud/food_half",
            "gui/sprites/hud/armor_empty", "gui/sprites/hud/armor_half", "gui/sprites/hud/armor_full",
            "gui/sprites/hud/experience_bar_background", "gui/sprites/hud/experience_bar_progress",
            "gui/sprites/hud/crosshair", "font/ascii",
    };

    /** Movement keys held in RE4. */
    public static class RemoteKeys {
        public boolean forward, back, left, right, jump, sneak, sprint, attack, use;
    }

    @Override
    public void onInitializeClient() {
        outputFile = loadOutputPath();
        inputFile = outputFile.resolveSibling("minecraft_bridge_input.json");
        syncFile = outputFile.resolveSibling("minecraft_bridge_sync.json");
        blocksFile = outputFile.resolveSibling("minecraft_blocks.json");
        texturesFile = outputFile.resolveSibling("minecraft_textures.json");
        pluginStatusFile = outputFile.resolveSibling("minecraft_overlay_plugin.json");
        terrainFile = outputFile.resolveSibling("minecraft_terrain.json");
        try {
            Files.createDirectories(outputFile.getParent());
        } catch (IOException e) {
            LOGGER.warn("RE4 Bridge: could not create {}", outputFile.getParent(), e);
        }
        OverlayStreamer.open(outputFile.resolveSibling("minecraft_overlay.bin"));
        Re4Puppet.init(outputFile.resolveSibling("minecraft_puppet.json"));
        Re4Input.init(outputFile.resolveSibling("minecraft_mouse.json"));
        LOGGER.info("RE4 Bridge: writing HUD data to {}, reading input from {}", outputFile, inputFile);
    }

    public static boolean overlayActive() {
        return overlayActive;
    }

    /** End of a rendered frame: send the picture to RE4 while in overlay mode. */
    public static void onFrameRendered(Minecraft mc) {
        if (overlayActive && (!re4Turn || Re4Puppet.active()) && mc.level != null) {
            try {
                OverlayStreamer.capture(mc);
            } catch (Exception e) {
                warnOnce("could not capture the frame", e);
            }
        }
    }

    // Overlay mode on/off follows whether RE4 is in control; during RE4's turn the picture is hidden
    private static void updateOverlayMode(Minecraft mc) {
        boolean want = remoteKeys() != null && mc.player != null;
        if (want != overlayActive) {
            overlayActive = want;
            if (want) {
                enterOverlayMode(mc);
            } else {
                exitOverlayMode(mc);
            }
        }
        OverlayStreamer.setActive(overlayActive && (!re4Turn || Re4Puppet.active()));
        OverlayStreamer.setInputToRe4(re4Turn ? 2 : (re4Keys ? 1 : 0));
        OverlayStreamer.setScreenOpen(overlayActive && !re4Turn && mc.screen != null);
    }

    // The right mouse button held in RE4 = Minecraft's "use" key held (drawing bows, eating, blocking)
    private static void holdUseKey(Minecraft mc) {
        RemoteKeys remote = remoteKeys();
        boolean down = remote != null && remote.use && !re4Turn;
        if (remote != null || useHeldByRe4) {
            mc.options.keyUse.setDown(down);
            useHeldByRe4 = down;
        }
    }

    // New arrows from the player: Minecraft's arrow damage (speed x base damage, crits), applied in RE4
    private static void detectShots(Minecraft mc) {
        LocalPlayer player = mc.player;
        if (player == null || mc.level == null) {
            return;
        }
        for (Entity entity : mc.level.entitiesForRendering()) {
            if (entity instanceof AbstractArrow arrow && arrow.tickCount <= 3 && arrow.getOwner() == player
                    && seenArrows.add(arrow.getId())) {
                int damage = Mth.ceil(Mth.clamp(arrow.getDeltaMovement().length() * arrow.getBaseDamage(), 0.0, 1000.0));
                if (arrow.isCritArrow()) {
                    damage += damage / 4 + 1;   // vanilla adds a random 0..damage/2+1
                }
                lastShotDamage = damage;
                lastShotCrit = arrow.isCritArrow();
                shotSeq++;
                if (seenArrows.size() > 64) {
                    seenArrows.remove(seenArrows.iterator().next());
                }
            }
        }
    }

    private static void enterOverlayMode(Minecraft mc) {
        // Fast graphics: Fancy draws a dark vignette over the whole screen, which would darken RE4
        savedGraphics = mc.options.graphicsMode().get();
        mc.options.graphicsMode().set(GraphicsStatus.FAST);

        // Drawing only a hand and a HUD is so cheap Minecraft would run at hundreds of FPS; RE4 needs 60
        savedFramerate = mc.options.framerateLimit().get();
        mc.options.framerateLimit().set(OVERLAY_FPS);

        // Half of RE4's screen size with GUI scale 2 = Minecraft's normal look, scaled up sharply 2x
        int width = 960;
        int height = 540;
        JsonObject status = readJson(pluginStatusFile);
        if (status != null && status.has("width") && status.has("height")) {
            re4ScreenWidth = status.get("width").getAsInt();
            int w = status.get("width").getAsInt() / 2;
            int h = status.get("height").getAsInt() / 2;
            if (w >= 320 && h >= 240 && w <= 1920 && h <= 1080) {
                width = w;
                height = h;
            }
        }
        if (mc.getWindow().isFullscreen()) {
            mc.getWindow().toggleFullScreen();
        }
        GLFW.glfwSetWindowSize(mc.getWindow().getWindow(), width, height);
        savedGuiScale = mc.options.guiScale().get();
        mc.options.guiScale().set(2);
        mc.resizeDisplay();
        LOGGER.info("RE4 Bridge: overlay mode on ({}x{})", width, height);
    }

    private static void exitOverlayMode(Minecraft mc) {
        if (savedGraphics != null) {
            mc.options.graphicsMode().set(savedGraphics);
        }
        if (savedGuiScale != null) {
            mc.options.guiScale().set(savedGuiScale);
        }
        if (savedFramerate != null) {
            mc.options.framerateLimit().set(savedFramerate);
        }
        mc.resizeDisplay();
        LOGGER.info("RE4 Bridge: overlay mode off");
    }

    /** The keys RE4 is holding, or null when RE4 isn't in control (then the keyboard works as usual). */
    public static RemoteKeys remoteKeys() {
        if (keys == null || System.currentTimeMillis() - lastInputTime > REMOTE_TIMEOUT_MS) {
            return null;
        }
        return keys;
    }

    // The output path lives in config/re4bridge.txt so it can be changed without rebuilding the mod
    private static Path loadOutputPath() {
        Path config = FabricLoader.getInstance().getConfigDir().resolve("re4bridge.txt");
        try {
            if (Files.notExists(config)) {
                Files.writeString(config,
                        "# Full path of the file the RE4 script reads (inside RE4's reframework\\data folder)\n"
                                + DEFAULT_OUTPUT + "\n",
                        StandardCharsets.UTF_8);
            }
            List<String> lines = Files.readAllLines(config, StandardCharsets.UTF_8);
            for (String line : lines) {
                String trimmed = line.trim();
                if (!trimmed.isEmpty() && !trimmed.startsWith("#")) {
                    return Paths.get(trimmed);
                }
            }
        } catch (IOException e) {
            LOGGER.warn("RE4 Bridge: could not read {}, using default path", config, e);
        }
        return Paths.get(DEFAULT_OUTPUT);
    }

    private static void warnOnce(String what, Exception e) {
        if (!warnedWrite) {
            LOGGER.warn("RE4 Bridge: {}", what, e);
            warnedWrite = true;
        }
    }

    // Start of the tick: take RE4's input now, so it affects the player in this same tick
    public static void onClientTickStart(Minecraft mc) {
        if (outputFile == null) {
            return;
        }
        try {
            applyInput(mc);
            handleTerrain(mc);
            if (!Re4Terrain.enforced()) {
                applySync(mc);
            }
            continueDestroying(mc);
            holdUseKey(mc);
            updateOverlayMode(mc);
        } catch (Exception e) {
            warnOnce("could not apply RE4 input", e);
        }
    }

    // End of the tick: send the result to RE4
    public static void onClientTick(Minecraft mc) {
        if (outputFile == null) {
            return;
        }
        // You play in the RE4 window, so Minecraft must keep running when it loses focus
        mc.options.pauseOnLostFocus = false;
        ticks++;

        try {
            if (mc.player != null && ticks % BLOCK_SCAN_EVERY_TICKS == 0) {
                writeBlocks(mc);
            }
            if (mc.player != null) {
                updateTextures(mc);
                detectShots(mc);
            }
            Re4Puppet.tick(mc);
            write(outputFile, buildState(mc).toString());
        } catch (Exception e) {
            warnOnce("could not write " + outputFile, e);
        }
    }

    private static Float finiteOrNull(float value) {
        return Float.isFinite(value) ? value : null;
    }

    private static boolean flag(JsonObject obj, String name) {
        return obj.has(name) && obj.get(name).getAsBoolean();
    }

    private static JsonObject readJson(Path file) {
        if (Files.notExists(file)) {
            return null;
        }
        try {
            JsonElement parsed = JsonParser.parseString(Files.readString(file, StandardCharsets.UTF_8));
            return parsed.isJsonObject() ? parsed.getAsJsonObject() : null;
        } catch (Exception e) {
            // RE4 may be writing the file right now; try again next tick
            return null;
        }
    }

    // Files left over from an earlier session must not count as RE4 being in control
    private static boolean isFresh(Path file) {
        try {
            return System.currentTimeMillis() - Files.getLastModifiedTime(file).toMillis() < REMOTE_TIMEOUT_MS;
        } catch (IOException e) {
            return false;
        }
    }

    private static void applyInput(Minecraft mc) {
        LocalPlayer player = mc.player;
        if (player == null || !isFresh(inputFile)) {
            return;
        }
        JsonObject input = readJson(inputFile);
        if (input == null) {
            return;
        }

        long inputSeq = input.has("seq") ? input.get("seq").getAsLong() : 0;
        if (inputSeq != lastInputSeq) {
            boolean firstRead = lastInputSeq == -1;
            lastInputSeq = inputSeq;
            lastInputTime = System.currentTimeMillis();

            if (input.has("keys") && input.get("keys").isJsonObject()) {
                JsonObject k = input.getAsJsonObject("keys");
                RemoteKeys next = new RemoteKeys();
                next.forward = flag(k, "w");
                next.back = flag(k, "s");
                next.left = flag(k, "a");
                next.right = flag(k, "d");
                next.jump = flag(k, "jump");
                next.sneak = flag(k, "sneak");
                next.sprint = flag(k, "sprint");
                next.attack = flag(k, "attack");
                next.use = flag(k, "use");
                keys = next;
            }
            re4Turn = input.has("re4_turn") && input.get("re4_turn").getAsBoolean();
            re4Keys = input.has("re4_keys") && input.get("re4_keys").getAsBoolean();
            if (input.has("brightness")) {
                float b = input.get("brightness").getAsFloat();
                if (Float.isFinite(b)) {
                    characterBrightness = Math.max(0.1F, Math.min(1.0F, b));
                }
            }
            remoteYaw = input.has("yaw") ? finiteOrNull(input.get("yaw").getAsFloat()) : null;
            remotePitch = input.has("pitch") ? finiteOrNull(input.get("pitch").getAsFloat()) : null;
            if (remotePitch != null) {
                remotePitch = Math.max(-90.0F, Math.min(90.0F, remotePitch));
            }

            // Only react when RE4 picks a new slot, so changing slots in Minecraft itself still works
            if (input.has("selected")) {
                int selected = input.get("selected").getAsInt();
                if (selected != lastInputSelected && selected >= 0 && selected <= 8 && !firstRead) {
                    player.getInventory().selected = selected;
                }
                lastInputSelected = selected;
            }

            // Counters: a lower count means the RE4 script was reloaded; just resync
            if (input.has("swings")) {
                int swings = input.get("swings").getAsInt();
                if (swings > lastInputSwings && !firstRead && mc.screen == null) {
                    // Every click counts (a few at most per tick; Minecraft's attack cooldown still applies)
                    for (int i = 0; i < Math.min(3, swings - lastInputSwings); i++) {
                        leftClick(mc, player);
                    }
                }
                lastInputSwings = swings;
            }
            if (input.has("uses")) {
                int uses = input.get("uses").getAsInt();
                if (uses > lastInputUses && !firstRead && mc.screen == null) {
                    // A real "use" click: Minecraft places, eats, draws a bow... and repeats while held
                    KeyMapping.click(InputConstants.getKey(mc.options.keyUse.saveString()));
                }
                lastInputUses = uses;
            }
            if (input.has("perspective")) {
                int perspective = input.get("perspective").getAsInt();
                if (perspective > lastInputPerspective && !firstRead) {
                    togglePerspective(mc);
                }
                lastInputPerspective = perspective;
            }
        }

        RemoteKeys remote = remoteKeys();
        if (remote == null) {
            return;
        }
        // Look where Leon looks, so Minecraft aims its placing and breaking at the same spot
        // (not in a cutscene: then your character faces where Leon faces)
        if (remoteYaw != null && remotePitch != null && !Re4Puppet.active()) {
            player.setYRot(remoteYaw);
            player.setXRot(remotePitch);
            player.yRotO = remoteYaw;
            player.xRotO = remotePitch;
            player.setYHeadRot(remoteYaw);
        }
        // Sprinting is started by the sprint key in LocalPlayer.aiStep, which reads the real keyboard
        if (remote.sprint && remote.forward && !remote.sneak) {
            player.setSprinting(true);
        }
    }

    public static void teleportPlayer(Minecraft mc, LocalPlayer player, double x, double y, double z) {
        teleport(mc, player, x, y, z);
    }

    // Moves the player on the client and on the integrated server, without falling damage
    private static void teleport(Minecraft mc, LocalPlayer player, double x, double y, double z) {
        player.setPos(x, y, z);
        player.setDeltaMovement(Vec3.ZERO);
        player.resetFallDistance();
        var server = mc.getSingleplayerServer();
        if (server != null) {
            var uuid = player.getUUID();
            server.execute(() -> {
                ServerPlayer serverPlayer = server.getPlayerList().getPlayer(uuid);
                if (serverPlayer != null) {
                    serverPlayer.teleportTo(x, y, z);
                    serverPlayer.resetFallDistance();
                }
            });
        }
    }

    // RE4's terrain: new anchors on request, new terrain snapshots as they arrive
    private static void handleTerrain(Minecraft mc) {
        LocalPlayer player = mc.player;
        if (player == null) {
            return;
        }
        boolean control = remoteKeys() != null;
        JsonObject terrain = isFresh(terrainFile) ? readJson(terrainFile) : null;
        if (terrain != null) {
            long request = terrain.has("request_epoch") ? terrain.get("request_epoch").getAsLong() : 0;
            if (control && request != 0 && request != Re4Terrain.anchorEpoch()) {
                anchorAt(mc, player, request);
            }
            // After one of RE4's own actions (ladder, door, cutscene) RE4 asks to move the player to Leon
            long epoch = terrain.has("epoch") ? terrain.get("epoch").getAsLong() : 0;
            if (control && terrain.has("sync") && epoch != 0 && epoch == Re4Terrain.anchorEpoch()) {
                JsonObject sync = terrain.getAsJsonObject("sync");
                long syncSeq = sync.get("seq").getAsLong();
                if (syncSeq != syncDone) {
                    double x = sync.get("x").getAsDouble(), y = sync.get("y").getAsDouble(), z = sync.get("z").getAsDouble();
                    if (Double.isFinite(x) && Double.isFinite(y) && Double.isFinite(z)) {
                        teleport(mc, player, x, y, z);
                    }
                    syncDone = syncSeq;
                }
            }
            // RE4's enemies near Leon, for their Minecraft stand-ins
            if (control && epoch != 0 && epoch == Re4Terrain.anchorEpoch() && terrain.has("enemies")) {
                Re4Enemies.setTargets(terrain.get("enemies").getAsString());
            } else {
                Re4Enemies.clearTargets();
            }
            long seq = terrain.has("seq") ? terrain.get("seq").getAsLong() : -1;
            if (seq != lastTerrainSeq) {
                lastTerrainSeq = seq;
                try {
                    Re4Terrain.load(terrain);
                } catch (RuntimeException e) {
                    warnOnce("bad terrain message", e);
                }
            }
        }
        if (terrain == null) {
            Re4Enemies.clearTargets();
        }
        Re4Terrain.setEnforced(control);

        // The stand-ins live on the integrated server
        var server = mc.getSingleplayerServer();
        if (server != null) {
            var uuid = player.getUUID();
            server.execute(() -> Re4Enemies.update(server, uuid));
        }
    }

    private static void anchorAt(Minecraft mc, LocalPlayer player, long epoch) {
        double x = player.getX();
        double z = player.getZ();
        teleport(mc, player, x, ANCHOR_Y, z);
        Re4Terrain.setAnchor(epoch, x, ANCHOR_Y, z);
        lastTerrainSeq = -1;
        LOGGER.info("RE4 Bridge: anchored epoch {} at {} {} {}", epoch, x, ANCHOR_Y, z);
    }

    // RE4's walls can stop Leon while Minecraft's player keeps walking; move it back next to Leon
    private static void applySync(Minecraft mc) {
        LocalPlayer player = mc.player;
        if (player == null || remoteKeys() == null) {
            return;
        }
        JsonObject sync = readJson(syncFile);
        if (sync == null || !flag(sync, "active") || !sync.has("seq")) {
            return;
        }
        long syncSeq = sync.get("seq").getAsLong();
        if (syncSeq == lastSyncSeq) {
            return;
        }
        lastSyncSeq = syncSeq;
        double x = sync.get("x").getAsDouble();
        double z = sync.get("z").getAsDouble();
        if (!Double.isFinite(x) || !Double.isFinite(z)) {
            return;
        }
        double dx = player.getX() - x;
        double dz = player.getZ() - z;
        double distance2 = dx * dx + dz * dz;
        if (distance2 > SYNC_DISTANCE * SYNC_DISTANCE && distance2 <= SYNC_MAX_DISTANCE * SYNC_MAX_DISTANCE) {
            player.setPos(x, player.getY(), z);
        }
    }

    // A real block the player looks at (not RE4's ground, which is only a place to put blocks on)
    private static BlockHitResult lookedAtBlock(LocalPlayer player) {
        HitResult hit = player.pick(player.blockInteractionRange(), 1.0F, false);
        if (hit instanceof BlockHitResult blockHit && hit.getType() == HitResult.Type.BLOCK
                && !player.level().getBlockState(blockHit.getBlockPos()).isAir()) {
            return blockHit;
        }
        return null;
    }

    // Left click: break the looked-at block like Minecraft does, otherwise attack (RE4 applies the damage)
    private static void leftClick(Minecraft mc, LocalPlayer player) {
        // Aim with RE4's newest look direction, not the one from Minecraft's last frame
        if (remoteYaw != null && remotePitch != null && !Re4Puppet.active()) {
            player.setYRot(remoteYaw);
            player.setXRot(remotePitch);
        }
        mc.gameRenderer.pick(1.0F);
        // A Minecraft mob, or the stand-in of an RE4 enemy, in the crosshair: Minecraft's own attack
        if (mc.hitResult instanceof EntityHitResult hit && mc.gameMode != null) {
            mc.gameMode.attack(player, hit.getEntity());
            player.swing(InteractionHand.MAIN_HAND);
            return;
        }
        // An RE4 enemy close in front, even if the crosshair isn't exactly on its stand-in, wins over a block
        // farther away: still Minecraft's own attack (sounds, crit sparks, damage hearts, knockback,
        // enchantments), and the damage goes to the RE4 enemy
        BlockHitResult block = lookedAtBlock(player);
        Entity standIn = standInInFront(mc, player);
        Vec3 eye = player.getEyePosition();
        double blockDistance = block != null ? block.getLocation().distanceTo(eye) : Double.MAX_VALUE;
        if (standIn != null && mc.gameMode != null && Math.sqrt(standIn.getBoundingBox().distanceToSqr(eye)) <= blockDistance) {
            mc.gameMode.attack(player, standIn);
            player.swing(InteractionHand.MAIN_HAND);
            return;
        }
        if (block != null && mc.gameMode != null) {
            mc.gameMode.startDestroyBlock(block.getBlockPos(), block.getDirection());
            destroying = true;
            player.swing(InteractionHand.MAIN_HAND);
            return;
        }
        attack(player);
    }

    // The RE4 enemy stand-in best in line with the crosshair within reach, or null. Aims at the nearest point
    // of its body (not one spot), takes an enemy right up close even off-center, and one the camera is inside.
    private static Entity standInInFront(Minecraft mc, LocalPlayer player) {
        if (mc.level == null) {
            return null;
        }
        Vec3 eye = player.getEyePosition();
        Vec3 look = player.getViewVector(1.0F);
        double reach = player.entityInteractionRange();
        Entity best = null;
        double bestScore = 0.0;
        for (Entity entity : mc.level.entitiesForRendering()) {
            if (!Re4Enemies.isStandIn(entity) || !entity.isAlive()) {
                continue;
            }
            AABB box = entity.getBoundingBox();
            Vec3 nearest = new Vec3(Mth.clamp(eye.x, box.minX, box.maxX), Mth.clamp(eye.y, box.minY, box.maxY),
                    Mth.clamp(eye.z, box.minZ, box.maxZ));
            Vec3 toNearest = nearest.subtract(eye);
            double distance = toNearest.length();
            if (distance > reach) {
                continue;
            }
            Vec3 toCenter = box.getCenter().subtract(eye);
            double aim = Math.max(distance < 0.01 ? 1.0 : toNearest.dot(look) / distance,
                    toCenter.length() < 0.01 ? 1.0 : toCenter.dot(look) / toCenter.length());
            boolean ok = aim > 0.75 || (distance < 1.2 && aim > 0.2) || distance < 0.05;
            double score = aim - distance * 0.05;
            if (ok && (best == null || score > bestScore)) {
                best = entity;
                bestScore = score;
            }
        }
        return best;
    }

    // Survival mining: keep digging while RE4 holds the mouse button, like holding it in Minecraft
    private static void continueDestroying(Minecraft mc) {
        LocalPlayer player = mc.player;
        RemoteKeys remote = remoteKeys();
        if (player == null || mc.gameMode == null || !destroying) {
            return;
        }
        BlockHitResult block = lookedAtBlock(player);
        if (remote == null || !remote.attack || block == null) {
            mc.gameMode.stopDestroyBlock();
            destroying = false;
            return;
        }
        if (mc.gameMode.continueDestroyBlock(block.getBlockPos(), block.getDirection())) {
            player.swing(InteractionHand.MAIN_HAND);
        }
    }

    // Right click: Minecraft's own "use" (places the held block, opens doors, eats food...)

    // Minecraft's attack math: cooldown, attack damage attribute, critical hits. RE4 applies the result.
    private static void attack(LocalPlayer player) {
        float strength = player.getAttackStrengthScale(0.5F);
        float damage = (float) player.getAttributeValue(Attributes.ATTACK_DAMAGE);
        boolean crit = strength > 0.9F && player.fallDistance > 0.0F && !player.onGround()
                && !player.onClimbable() && !player.isInWater() && !player.isPassenger() && !player.isSprinting();

        float total = damage * (0.2F + strength * strength * 0.8F);
        if (crit) {
            total *= 1.5F;
        }

        attackSeq++;
        lastAttackDamage = total;
        lastAttackStrength = strength;
        lastAttackCrit = crit;

        player.swing(InteractionHand.MAIN_HAND);
        player.resetAttackStrengthTicker();
    }

    // What F5 does in Minecraft: first person -> behind -> in front
    private static void togglePerspective(Minecraft mc) {
        CameraType before = mc.options.getCameraType();
        mc.options.setCameraType(before.cycle());
        if (before.isFirstPerson() != mc.options.getCameraType().isFirstPerson()) {
            mc.gameRenderer.checkEntityPostEffect(mc.options.getCameraType().isFirstPerson() ? mc.getCameraEntity() : null);
        }
        mc.levelRenderer.needsUpdate();
    }

    private static JsonObject buildState(Minecraft mc) {
        JsonObject state = new JsonObject();
        state.addProperty("seq", ++seq);

        LocalPlayer player = mc.player;
        state.addProperty("in_world", player != null);
        if (player == null) {
            return state;
        }

        state.addProperty("health", player.getHealth());
        state.addProperty("max_health", player.getMaxHealth());
        state.addProperty("absorption", player.getAbsorptionAmount());
        state.addProperty("armor", player.getArmorValue());
        state.addProperty("food", player.getFoodData().getFoodLevel());
        state.addProperty("xp_level", player.experienceLevel);
        state.addProperty("xp_progress", player.experienceProgress);
        state.addProperty("selected", player.getInventory().selected);
        state.addProperty("game_mode", mc.gameMode != null ? mc.gameMode.getPlayerMode().getName() : "unknown");
        state.addProperty("re4_control", remoteKeys() != null);
        state.addProperty("overlay", overlayActive);
        // A Minecraft screen is open (inventory, creative menu, chat): RE4's scripts stop looking and moving
        state.addProperty("screen_open", overlayActive && !re4Turn && mc.screen != null);
        // Mouse settings, so RE4's mouse look turns exactly like Minecraft's
        state.addProperty("sensitivity", mc.options.sensitivity().get());
        state.addProperty("invert_mouse", mc.options.invertYMouse().get());
        state.addProperty("blocks_version", blocksVersion);
        state.addProperty("textures_version", texturesVersion);

        // The keys this tick used, so RE4 knows when Minecraft has caught up with a key press
        RemoteKeys used = remoteKeys();
        if (used != null) {
            JsonObject k = new JsonObject();
            k.addProperty("w", used.forward);
            k.addProperty("a", used.left);
            k.addProperty("s", used.back);
            k.addProperty("d", used.right);
            k.addProperty("jump", used.jump);
            k.addProperty("sneak", used.sneak);
            k.addProperty("sprint", used.sprint);
            state.add("keys", k);
        }

        JsonObject pos = new JsonObject();
        pos.addProperty("x", player.getX());
        pos.addProperty("y", player.getY());
        pos.addProperty("z", player.getZ());
        state.add("pos", pos);
        state.addProperty("flat_y", flatY);

        BlockHitResult target = lookedAtBlock(player);
        if (target != null) {
            JsonObject t = new JsonObject();
            t.addProperty("x", target.getBlockPos().getX());
            t.addProperty("y", target.getBlockPos().getY());
            t.addProperty("z", target.getBlockPos().getZ());
            state.add("target", t);
        }

        state.add("move", describeMovement(player));

        // Camera: 0 = first person, 1 = third person behind, 2 = third person in front
        JsonObject camera = new JsonObject();
        CameraType cameraType = mc.options.getCameraType();
        camera.addProperty("mode", cameraType.ordinal());
        camera.addProperty("distance", cameraType.isFirstPerson() ? 0.0F : cameraDistance);
        camera.addProperty("fov", worldFov);
        state.add("camera", camera);

        // Terrain: the anchor between the worlds, and whether Minecraft's player walks on fresh RE4 terrain
        JsonObject anchor = new JsonObject();
        double[] a = Re4Terrain.anchor();
        anchor.addProperty("epoch", Re4Terrain.anchorEpoch());
        anchor.addProperty("x", a[0]);
        anchor.addProperty("y", a[1]);
        anchor.addProperty("z", a[2]);
        state.add("anchor", anchor);
        // Covered = fresh terrain around the player, and the player is at the terrain's height (not fallen away)
        boolean covered = Re4Terrain.covers(player.getX(), player.getZ())
                && Math.abs(player.getY() - a[1]) < 64.0;
        state.addProperty("terrain_boxes", Re4Terrain.boxCount());
        state.addProperty("authority", Re4Terrain.enforced() && covered);
        state.addProperty("sync_done", syncDone);

        // Damage Minecraft did to RE4's enemies through their stand-ins (totals per enemy)
        JsonObject enemyDamage = new JsonObject();
        for (Map.Entry<String, Float> entry : Re4Enemies.damageTotals().entrySet()) {
            enemyDamage.addProperty(entry.getKey(), entry.getValue());
        }
        state.add("enemy_damage", enemyDamage);

        JsonObject shot = new JsonObject();
        shot.addProperty("seq", shotSeq);
        shot.addProperty("damage", lastShotDamage);
        shot.addProperty("crit", lastShotCrit);
        state.add("shot", shot);

        JsonObject attack = new JsonObject();
        attack.addProperty("seq", attackSeq);
        attack.addProperty("damage", lastAttackDamage);
        attack.addProperty("strength", lastAttackStrength);
        attack.addProperty("crit", lastAttackCrit);
        attack.addProperty("cooldown", player.getAttackStrengthScale(0.0F));
        state.add("attack", attack);

        // Slots are keyed "s0".."s8" instead of a JSON array to avoid 0/1-based index confusion in Lua
        JsonObject hotbar = new JsonObject();
        for (int i = 0; i < 9; i++) {
            hotbar.add("s" + i, describe(player.getInventory().getItem(i)));
        }
        state.add("hotbar", hotbar);
        return state;
    }

    // How far the player moved this tick, relative to where they face, and how high they are above
    // the flat ground (jumping, flying or standing on placed blocks)
    private static JsonObject describeMovement(LocalPlayer player) {
        double dx = player.getX() - player.xo;
        double dy = player.getY() - player.yo;
        double dz = player.getZ() - player.zo;
        double yaw = Math.toRadians(player.getYRot());
        double forward = dx * -Math.sin(yaw) + dz * Math.cos(yaw);
        double right = dx * -Math.cos(yaw) + dz * -Math.sin(yaw);

        // The Superflat ground is the lowest place the player has stood on
        if (player.onGround() && (Double.isNaN(flatY) || player.getY() < flatY - 0.01)) {
            flatY = player.getY();
        }

        JsonObject move = new JsonObject();
        move.addProperty("forward", forward);
        move.addProperty("right", right);
        // The same movement in world directions; RE4 uses these directly (its look direction is Minecraft's)
        move.addProperty("dx", dx);
        move.addProperty("dz", dz);
        move.addProperty("up", dy);
        move.addProperty("elevation", Double.isNaN(flatY) ? 0.0 : Math.max(0.0, player.getY() - flatY));
        move.addProperty("on_ground", player.onGround());
        move.addProperty("flying", player.getAbilities().flying);
        move.addProperty("sprinting", player.isSprinting());
        move.addProperty("sneaking", player.isShiftKeyDown());
        return move;
    }

    private static JsonObject describe(ItemStack stack) {
        JsonObject item = new JsonObject();
        if (stack.isEmpty()) {
            return item;
        }
        item.addProperty("id", BuiltInRegistries.ITEM.getKey(stack.getItem()).toString());
        item.addProperty("count", stack.getCount());
        item.addProperty("enchanted", stack.hasFoil());
        if (stack.isDamageableItem()) {
            item.addProperty("damage", stack.getDamageValue());
            item.addProperty("max_damage", stack.getMaxDamage());
        }
        if (stack.getItem() instanceof CrossbowItem) {
            item.addProperty("charged", CrossbowItem.isCharged(stack));
        }
        return item;
    }

    // ---------------------------------------------------------------------------------------------
    // Blocks around the player (only above the flat ground, i.e. what you built)
    // ---------------------------------------------------------------------------------------------

    private static void writeBlocks(Minecraft mc) throws IOException {
        LocalPlayer player = mc.player;
        if (player == null || Double.isNaN(flatY)) {
            return;
        }
        int minY = (int) Math.floor(flatY);
        BlockPos center = player.blockPosition();
        JsonObject blocks = new JsonObject();
        JsonObject colors = new JsonObject();
        BlockPos.MutableBlockPos p = new BlockPos.MutableBlockPos();
        for (int x = -BLOCK_SCAN_RADIUS; x <= BLOCK_SCAN_RADIUS; x++) {
            for (int z = -BLOCK_SCAN_RADIUS; z <= BLOCK_SCAN_RADIUS; z++) {
                for (int y = minY; y <= minY + BLOCK_SCAN_HEIGHT; y++) {
                    p.set(center.getX() + x, y, center.getZ() + z);
                    BlockState state = player.level().getBlockState(p);
                    if (state.isAir()) {
                        continue;
                    }
                    String name = BuiltInRegistries.BLOCK.getKey(state.getBlock()).getPath();
                    blocks.addProperty(p.getX() + "," + p.getY() + "," + p.getZ(), name);
                    if (!colors.has(name)) {
                        colors.addProperty(name, blockColor(mc, name));
                    }
                }
            }
        }
        JsonObject out = new JsonObject();
        out.add("blocks", blocks);
        out.add("colors", colors);
        String json = out.toString();
        if (!json.equals(lastBlocksJson)) {
            lastBlocksJson = json;
            blocksVersion++;
            out.addProperty("version", blocksVersion);
            write(blocksFile, out.toString());
        }
    }

    // "RRGGBB,RRGGBB": average color of the block's top and side textures
    private static String blockColor(Minecraft mc, String name) {
        return blockColors.computeIfAbsent(name, n -> {
            int[] top = firstTexture(mc, "block/" + n + "_top", "block/" + n);
            int[] side = firstTexture(mc, "block/" + n + "_side", "block/" + n, "block/" + n + "_front");
            int topColor = top != null ? averageRgb(top, n, true) : 0x808080;
            int sideColor = side != null ? averageRgb(side, n, false) : topColor;
            return String.format("%06X,%06X", topColor, sideColor);
        });
    }

    // Grass and leaves textures are gray in the files; Minecraft tints them green
    private static int averageRgb(int[] abgr, String name, boolean top) {
        long r = 0, g = 0, b = 0, n = 0;
        for (int c : abgr) {
            if (((c >>> 24) & 0xFF) < 16) {
                continue;
            }
            r += c & 0xFF;
            g += (c >> 8) & 0xFF;
            b += (c >> 16) & 0xFF;
            n++;
        }
        if (n == 0) {
            return 0x808080;
        }
        int ri = (int) (r / n), gi = (int) (g / n), bi = (int) (b / n);
        boolean tinted = name.contains("leaves") || (name.equals("grass_block") && top) || name.contains("vine")
                || name.equals("short_grass") || name.equals("tall_grass") || name.contains("fern");
        if (tinted) {
            ri = ri * 0x79 / 255;
            gi = gi * 0xC0 / 255;
            bi = bi * 0x5A / 255;
        }
        return (ri << 16) | (gi << 8) | bi;
    }

    // ---------------------------------------------------------------------------------------------
    // Item textures for the HUD
    // ---------------------------------------------------------------------------------------------

    private static void updateTextures(Minecraft mc) throws IOException {
        LocalPlayer player = mc.player;
        boolean added = false;
        if (guiImages == null) {
            guiImages = new JsonObject();
            for (String name : GUI_IMAGES) {
                JsonObject image = readImage(mc, "textures/" + name + ".png");
                if (image != null) {
                    guiImages.add(name, image);
                }
            }
            added = true;
        }
        for (int i = 0; i < 9; i++) {
            ItemStack stack = player.getInventory().getItem(i);
            if (stack.isEmpty()) {
                continue;
            }
            String id = BuiltInRegistries.ITEM.getKey(stack.getItem()).toString();
            if (itemTextures.containsKey(id)) {
                continue;
            }
            String name = BuiltInRegistries.ITEM.getKey(stack.getItem()).getPath();
            int[] pixels = firstTexture(mc, "item/" + name, "block/" + name, "block/" + name + "_side",
                    "block/" + name + "_front", "block/" + name + "_top");
            itemTextures.put(id, pixels == null ? "" : toHex(pixels));
            added = true;
        }
        if (added) {
            texturesVersion++;
            JsonObject out = new JsonObject();
            out.addProperty("version", texturesVersion);
            JsonObject items = new JsonObject();
            itemTextures.forEach(items::addProperty);
            out.add("items", items);
            out.add("gui", guiImages);
            write(texturesFile, out.toString());
        }
    }

    // 256 pixels as "AABBGGRR" hex each: the same color format RE4's draw functions use
    private static String toHex(int[] abgr) {
        StringBuilder sb = new StringBuilder(abgr.length * 8);
        for (int c : abgr) {
            sb.append(String.format("%08X", c));
        }
        return sb.toString();
    }

    private static int[] firstTexture(Minecraft mc, String... paths) {
        for (String path : paths) {
            int[] pixels = readTexture(mc, "textures/" + path + ".png");
            if (pixels != null) {
                return pixels;
            }
        }
        return null;
    }

    // 16x16 pixels (first animation frame, scaled if a resource pack uses another size), ABGR ints
    private static int[] readTexture(Minecraft mc, String path) {
        Optional<Resource> resource = mc.getResourceManager().getResource(ResourceLocation.withDefaultNamespace(path));
        if (resource.isEmpty()) {
            return null;
        }
        try (InputStream in = resource.get().open(); NativeImage image = NativeImage.read(in)) {
            int size = image.getWidth();
            int[] pixels = new int[256];
            for (int y = 0; y < 16; y++) {
                for (int x = 0; x < 16; x++) {
                    pixels[y * 16 + x] = image.getPixelRGBA(x * size / 16, y * size / 16);
                }
            }
            return pixels;
        } catch (IOException e) {
            return null;
        }
    }

    // A whole image at its own size: { w, h, px = "AABBGGRR" hex per pixel, row by row }
    private static JsonObject readImage(Minecraft mc, String path) {
        Optional<Resource> resource = mc.getResourceManager().getResource(ResourceLocation.withDefaultNamespace(path));
        if (resource.isEmpty()) {
            return null;
        }
        try (InputStream in = resource.get().open(); NativeImage image = NativeImage.read(in)) {
            int w = image.getWidth();
            int h = image.getHeight();
            StringBuilder sb = new StringBuilder(w * h * 8);
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    sb.append(String.format("%08X", image.getPixelRGBA(x, y)));
                }
            }
            JsonObject out = new JsonObject();
            out.addProperty("w", w);
            out.addProperty("h", h);
            out.addProperty("px", sb.toString());
            return out;
        } catch (IOException e) {
            return null;
        }
    }

    // Write to a temp file and swap it in, so RE4 never reads a half-written file
    private static void write(Path file, String json) throws IOException {
        Files.createDirectories(file.getParent());
        Path tmp = file.resolveSibling(file.getFileName() + ".tmp");
        Files.writeString(tmp, json, StandardCharsets.UTF_8);
        try {
            Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            // RE4 may be reading the file right now; skip this tick, the next one will succeed
            Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING);
        }
    }
}
