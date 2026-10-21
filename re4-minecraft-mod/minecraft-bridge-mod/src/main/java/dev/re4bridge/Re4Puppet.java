package dev.re4bridge;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.Vec3;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/**
 * Your character plays Leon in RE4's cutscenes (minecraft_cutscenes.lua writes minecraft_puppet.json every
 * frame): the player follows Leon's moves and facing, its arms and legs take Leon's angles, and the camera
 * takes RE4's cutscene camera (position, direction, field of view), so the overlay shows your character
 * exactly where Leon would be. Positions are relative to where Leon and the player were when the scene
 * started.
 */
public final class Re4Puppet {
    private static final long STALE_MS = 500;
    private static final double TELEPORT_DISTANCE = 8.0;

    private static Path file;
    private static long fileModified = -1;
    private static long readAt = 0;

    private static volatile boolean active = false;
    private static long session = -1;
    private static double bodyX, bodyY, bodyZ;
    private static float bodyYaw;
    private static boolean hasCamera = false;
    private static double camX, camY, camZ;
    private static float camYaw, camPitch;
    private static double camFov = 70.0;
    private static final Map<String, float[]> limbs = new HashMap<>();

    // The player's position when the scene started
    private static Vec3 origin = null;
    private static long originSession = -1;
    private static volatile Entity puppet = null;
    private static boolean hidGui = false;

    private Re4Puppet() {
    }

    public static void init(Path puppetFile) {
        file = puppetFile;
    }

    /** Render thread, every frame: read the newest data from RE4. */
    public static void onRenderFrame(Minecraft mc) {
        if (file == null) {
            return;
        }
        try {
            long modified = Files.getLastModifiedTime(file).toMillis();
            if (modified != fileModified) {
                fileModified = modified;
                parse(JsonParser.parseString(Files.readString(file, StandardCharsets.UTF_8)).getAsJsonObject());
                readAt = System.currentTimeMillis();
            }
        } catch (Exception e) {
            // missing or half-written file: keep the last data
        }
        boolean fresh = System.currentTimeMillis() - readAt < STALE_MS
                && System.currentTimeMillis() - fileModified < STALE_MS * 4;
        active = fresh && sceneOn && Re4Bridge.overlayActive() && mc.player != null;
        if (!active) {
            puppet = null;
        }
    }

    private static boolean sceneOn = false;

    private static void parse(JsonObject data) {
        sceneOn = data.has("active") && data.get("active").getAsBoolean();
        if (!sceneOn) {
            return;
        }
        session = data.has("session") ? data.get("session").getAsLong() : 0;
        if (data.has("body")) {
            JsonObject b = data.getAsJsonObject("body");
            bodyX = b.get("x").getAsDouble();
            bodyY = b.get("y").getAsDouble();
            bodyZ = b.get("z").getAsDouble();
            bodyYaw = b.get("yaw").getAsFloat();
        }
        hasCamera = data.has("camera");
        if (hasCamera) {
            JsonObject c = data.getAsJsonObject("camera");
            camX = c.get("x").getAsDouble();
            camY = c.get("y").getAsDouble();
            camZ = c.get("z").getAsDouble();
            camYaw = c.get("yaw").getAsFloat();
            camPitch = c.get("pitch").getAsFloat();
            double fov = c.get("fov").getAsDouble();
            if (Double.isFinite(fov) && fov > 1.0 && fov < 170.0) {
                camFov = fov;
            }
        }
        synchronized (limbs) {
            limbs.clear();
            if (data.has("limbs") && data.get("limbs").isJsonObject()) {
                for (Map.Entry<String, com.google.gson.JsonElement> entry : data.getAsJsonObject("limbs").entrySet()) {
                    if (entry.getValue().isJsonObject()) {
                        JsonObject l = entry.getValue().getAsJsonObject();
                        float x = l.get("x").getAsFloat(), z = l.get("z").getAsFloat();
                        if (Float.isFinite(x) && Float.isFinite(z)) {
                            limbs.put(entry.getKey(), new float[] {x, z});
                        }
                    }
                }
            }
        }
    }

    public static boolean active() {
        return active;
    }

    public static boolean isPuppet(Entity entity) {
        return active && entity != null && entity == puppet;
    }

    /** Client tick: start or end a scene, move far jumps at once, hide the HUD while it plays. */
    public static void tick(Minecraft mc) {
        LocalPlayer player = mc.player;
        if (!active || player == null) {
            origin = null;
            if (hidGui) {
                mc.options.hideGui = false;
                hidGui = false;
            }
            return;
        }
        if (origin == null || originSession != session) {
            origin = player.position().subtract(bodyX, bodyY, bodyZ);
            originSession = session;
        }
        puppet = player;
        if (!mc.options.hideGui) {
            mc.options.hideGui = true;
            hidGui = true;
        }
        // Cutscene cuts can put Leon somewhere else at once
        Vec3 target = bodyTarget();
        if (target != null && target.distanceTo(player.position()) > TELEPORT_DISTANCE) {
            Re4Bridge.teleportPlayer(mc, player, target.x, target.y, target.z);
        }
    }

    /** Where the player should be now (Leon's spot), or null. */
    public static Vec3 bodyTarget() {
        Vec3 o = origin;
        return o == null ? null : o.add(bodyX, bodyY, bodyZ);
    }

    public static float bodyYaw() {
        return bodyYaw;
    }

    public static boolean hasCamera() {
        return active && hasCamera && origin != null;
    }

    public static Vec3 cameraPosition() {
        return origin.add(camX, camY, camZ);
    }

    public static float cameraYaw() {
        return camYaw;
    }

    public static float cameraPitch() {
        return camPitch;
    }

    public static double fov() {
        return camFov;
    }

    /** Leon's angles for a Minecraft limb ("right_arm", "left_leg"...): {xRot, zRot}, or null. */
    public static float[] limb(String name) {
        synchronized (limbs) {
            return limbs.get(name);
        }
    }
}
