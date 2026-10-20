package dev.re4bridge;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.item.CrossbowItem;
import net.minecraft.world.item.ItemStack;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.List;

/**
 * Bridge between Minecraft and the RE4 REFramework scripts, through two JSON files in RE4's
 * reframework\data folder:
 * - minecraft_bridge.json (written here): HUD state, the player's movement this tick, and attacks.
 * - minecraft_bridge_input.json (written by RE4): keys held in RE4, hotbar slot, swings.
 * Minecraft's own code does the movement and attack math; RE4 only applies the results to Leon.
 */
public class Re4Bridge implements ClientModInitializer {
    public static final Logger LOGGER = LoggerFactory.getLogger("re4bridge");

    private static final String DEFAULT_OUTPUT =
            "D:\\SteamLibrary\\steamapps\\common\\RESIDENT EVIL 4  BIOHAZARD RE4\\reframework\\data\\minecraft_bridge.json";

    // RE4 sends a heartbeat several times per second; without one for this long, the keyboard takes over again
    private static final long REMOTE_TIMEOUT_MS = 1500;

    private static Path outputFile;
    private static Path inputFile;
    private static long seq = 0;
    private static boolean warnedWrite = false;

    private static long lastInputSeq = -1;
    private static long lastInputTime = 0;
    private static int lastInputSelected = -1;
    private static int lastInputSwings = -1;
    private static RemoteKeys keys = null;

    private static double groundY = Double.NaN;
    private static long attackSeq = 0;
    private static float lastAttackDamage = 0;
    private static float lastAttackStrength = 0;
    private static boolean lastAttackCrit = false;

    /** Movement keys held in RE4. */
    public static class RemoteKeys {
        public boolean forward, back, left, right, jump, sneak, sprint;
    }

    @Override
    public void onInitializeClient() {
        outputFile = loadOutputPath();
        inputFile = outputFile.resolveSibling("minecraft_bridge_input.json");
        LOGGER.info("RE4 Bridge: writing HUD data to {}, reading input from {}", outputFile, inputFile);
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

    public static void onClientTick(Minecraft mc) {
        if (outputFile == null) {
            return;
        }
        // You play in the RE4 window, so Minecraft must keep running when it loses focus
        mc.options.pauseOnLostFocus = false;

        try {
            applyInput(mc);
            write(buildState(mc).toString());
        } catch (Exception e) {
            if (!warnedWrite) {
                LOGGER.warn("RE4 Bridge: could not write {}", outputFile, e);
                warnedWrite = true;
            }
        }
    }

    private static boolean flag(JsonObject obj, String name) {
        return obj.has(name) && obj.get(name).getAsBoolean();
    }

    private static void applyInput(Minecraft mc) {
        LocalPlayer player = mc.player;
        if (player == null || Files.notExists(inputFile)) {
            return;
        }

        JsonObject input;
        try {
            JsonElement parsed = JsonParser.parseString(Files.readString(inputFile, StandardCharsets.UTF_8));
            if (!parsed.isJsonObject()) {
                return;
            }
            input = parsed.getAsJsonObject();
        } catch (Exception e) {
            // RE4 may be writing the file right now; try again next tick
            return;
        }

        long inputSeq = input.has("seq") ? input.get("seq").getAsLong() : 0;
        if (inputSeq == lastInputSeq) {
            return;
        }
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
            keys = next;
        }

        // Only react when RE4 picks a new slot, so changing slots in Minecraft itself still works
        if (input.has("selected")) {
            int selected = input.get("selected").getAsInt();
            if (selected != lastInputSelected && selected >= 0 && selected <= 8 && !firstRead) {
                player.getInventory().selected = selected;
            }
            lastInputSelected = selected;
        }

        if (input.has("swings")) {
            int swings = input.get("swings").getAsInt();
            // A lower count means the RE4 script was reloaded; just resync
            if (swings > lastInputSwings && !firstRead) {
                attack(player);
            }
            lastInputSwings = swings;
        }

        // Sprinting is started by the sprint key in LocalPlayer.aiStep, which reads the real keyboard
        RemoteKeys remote = remoteKeys();
        if (remote != null && remote.sprint && remote.forward && !remote.sneak) {
            player.setSprinting(true);
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

    // How far the player moved this tick, relative to where they face (so RE4 can apply it to Leon's camera
    // direction), plus the height above the last ground for jumps and flying
    private static JsonObject describeMovement(LocalPlayer player) {
        double dx = player.getX() - player.xo;
        double dy = player.getY() - player.yo;
        double dz = player.getZ() - player.zo;
        double yaw = Math.toRadians(player.getYRot());
        double forward = dx * -Math.sin(yaw) + dz * Math.cos(yaw);
        double right = dx * -Math.cos(yaw) + dz * -Math.sin(yaw);

        if (player.onGround() || Double.isNaN(groundY)) {
            groundY = player.getY();
        }

        JsonObject move = new JsonObject();
        move.addProperty("forward", forward);
        move.addProperty("right", right);
        move.addProperty("up", dy);
        move.addProperty("height", Math.max(0.0, player.getY() - groundY));
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

    // Write to a temp file and swap it in, so RE4 never reads a half-written file
    private static void write(String json) throws IOException {
        Files.createDirectories(outputFile.getParent());
        Path tmp = outputFile.resolveSibling(outputFile.getFileName() + ".tmp");
        Files.writeString(tmp, json, StandardCharsets.UTF_8);
        try {
            Files.move(tmp, outputFile, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            // RE4 may be reading the file right now; skip this tick, the next one will succeed
            Files.move(tmp, outputFile, StandardCopyOption.REPLACE_EXISTING);
        }
    }
}
