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
 * Writes the player's HUD state to a JSON file inside RE4's reframework\data folder,
 * where the minecraft_bridge_hud.lua REFramework script reads it, and applies the input
 * that script writes back (hotbar slot, swings).
 */
public class Re4Bridge implements ClientModInitializer {
    public static final Logger LOGGER = LoggerFactory.getLogger("re4bridge");

    private static final String DEFAULT_OUTPUT =
            "D:\\SteamLibrary\\steamapps\\common\\RESIDENT EVIL 4  BIOHAZARD RE4\\reframework\\data\\minecraft_bridge.json";

    private static Path outputFile;
    private static Path inputFile;
    private static long seq = 0;
    private static boolean warnedWrite = false;

    private static long lastInputSeq = -1;
    private static int lastInputSelected = -1;
    private static int lastInputSwings = -1;

    @Override
    public void onInitializeClient() {
        outputFile = loadOutputPath();
        inputFile = outputFile.resolveSibling("minecraft_bridge_input.json");
        LOGGER.info("RE4 Bridge: writing HUD data to {}, reading input from {}", outputFile, inputFile);
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

    // Input from RE4: "selected" = hotbar slot picked with 1-9, "swings" = left-click counter
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
                player.swing(InteractionHand.MAIN_HAND);
            }
            lastInputSwings = swings;
        }
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

        // Slots are keyed "s0".."s8" instead of a JSON array to avoid 0/1-based index confusion in Lua
        JsonObject hotbar = new JsonObject();
        for (int i = 0; i < 9; i++) {
            hotbar.add("s" + i, describe(player.getInventory().getItem(i)));
        }
        state.add("hotbar", hotbar);
        return state;
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
