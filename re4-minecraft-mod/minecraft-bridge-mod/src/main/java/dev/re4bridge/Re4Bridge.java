package dev.re4bridge;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.mojang.blaze3d.platform.NativeImage;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.GraphicsStatus;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.InteractionResult;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.item.CrossbowItem;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.BlockHitResult;
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
        public boolean forward, back, left, right, jump, sneak, sprint, attack;
    }

    @Override
    public void onInitializeClient() {
        outputFile = loadOutputPath();
        inputFile = outputFile.resolveSibling("minecraft_bridge_input.json");
        syncFile = outputFile.resolveSibling("minecraft_bridge_sync.json");
        blocksFile = outputFile.resolveSibling("minecraft_blocks.json");
        texturesFile = outputFile.resolveSibling("minecraft_textures.json");
        pluginStatusFile = outputFile.resolveSibling("minecraft_overlay_plugin.json");
        try {
            Files.createDirectories(outputFile.getParent());
        } catch (IOException e) {
            LOGGER.warn("RE4 Bridge: could not create {}", outputFile.getParent(), e);
        }
        OverlayStreamer.open(outputFile.resolveSibling("minecraft_overlay.bin"));
        LOGGER.info("RE4 Bridge: writing HUD data to {}, reading input from {}", outputFile, inputFile);
    }

    public static boolean overlayActive() {
        return overlayActive;
    }

    /** End of a rendered frame: send the picture to RE4 while in overlay mode. */
    public static void onFrameRendered(Minecraft mc) {
        if (overlayActive && mc.level != null) {
            try {
                OverlayStreamer.capture(mc);
            } catch (Exception e) {
                warnOnce("could not capture the frame", e);
            }
        }
    }

    // Overlay mode on/off follows whether RE4 is in control
    private static void updateOverlayMode(Minecraft mc) {
        boolean want = remoteKeys() != null && mc.player != null;
        if (want == overlayActive) {
            return;
        }
        overlayActive = want;
        if (want) {
            enterOverlayMode(mc);
        } else {
            exitOverlayMode(mc);
        }
        OverlayStreamer.setActive(want);
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
            applySync(mc);
            continueDestroying(mc);
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
            }
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

    private static void applyInput(Minecraft mc) {
        LocalPlayer player = mc.player;
        if (player == null) {
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
                keys = next;
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
                if (swings > lastInputSwings && !firstRead) {
                    leftClick(mc, player);
                }
                lastInputSwings = swings;
            }
            if (input.has("uses")) {
                int uses = input.get("uses").getAsInt();
                if (uses > lastInputUses && !firstRead) {
                    rightClick(mc, player);
                }
                lastInputUses = uses;
            }
        }

        RemoteKeys remote = remoteKeys();
        if (remote == null) {
            return;
        }
        // Look where Leon looks, so Minecraft aims its placing and breaking at the same spot
        if (remoteYaw != null && remotePitch != null) {
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

    private static BlockHitResult lookedAtBlock(LocalPlayer player) {
        HitResult hit = player.pick(player.blockInteractionRange(), 1.0F, false);
        if (hit instanceof BlockHitResult blockHit && hit.getType() == HitResult.Type.BLOCK) {
            return blockHit;
        }
        return null;
    }

    // Left click: break the looked-at block like Minecraft does, otherwise attack (RE4 applies the damage)
    private static void leftClick(Minecraft mc, LocalPlayer player) {
        BlockHitResult block = lookedAtBlock(player);
        if (block != null && mc.gameMode != null) {
            mc.gameMode.startDestroyBlock(block.getBlockPos(), block.getDirection());
            destroying = true;
            player.swing(InteractionHand.MAIN_HAND);
            return;
        }
        attack(player);
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
    private static void rightClick(Minecraft mc, LocalPlayer player) {
        if (mc.gameMode == null) {
            return;
        }
        BlockHitResult block = lookedAtBlock(player);
        if (block != null) {
            InteractionResult result = mc.gameMode.useItemOn(player, InteractionHand.MAIN_HAND, block);
            if (result.consumesAction()) {
                if (result.shouldSwing()) {
                    player.swing(InteractionHand.MAIN_HAND);
                }
                return;
            }
        }
        InteractionResult result = mc.gameMode.useItem(player, InteractionHand.MAIN_HAND);
        if (result.consumesAction() && result.shouldSwing()) {
            player.swing(InteractionHand.MAIN_HAND);
        }
    }

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
