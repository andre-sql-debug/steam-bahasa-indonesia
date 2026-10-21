package dev.re4bridge;

import net.minecraft.client.Minecraft;
import net.minecraft.world.phys.Vec3;

import java.util.concurrent.locks.LockSupport;

/**
 * Minecraft draws from RE4's own camera, frame by frame. The RE4 overlay plugin writes RE4's camera into the
 * shared overlay file right before RE4 renders each frame; here, before Minecraft renders, we wait for that
 * new camera, map it into Minecraft's world (through the terrain anchor), and draw with it. The picture is
 * tagged with the camera's number, and the plugin shows each RE4 frame with the Minecraft picture drawn for
 * it: Minecraft's blocks, mobs and hand stay exactly in place when you turn, instead of lagging behind.
 */
public final class Re4Camera {
    private static final long WAIT_NS = 20_000_000L;        // at most this long for RE4's next frame
    private static final long IDLE_FRAME_NS = 16_666_667L;  // without RE4's camera: about 60 pictures a second

    private static long lastSeq = 0;
    private static long renderedSeq = 0;
    private static long lastFrameNs = 0;
    private static volatile boolean active = false;
    private static Vec3 position = Vec3.ZERO;
    private static float yaw, pitch;
    private static double fov = 70.0;

    private Re4Camera() {
    }

    /**
     * Start of Minecraft's frame (before its ticks and its clock for smooth movement): wait until RE4 starts
     * drawing its next frame, so each Minecraft picture is drawn right when RE4 needs it.
     */
    public static void waitForRe4Frame() {
        if (!Re4Bridge.overlayActive()) {
            return;
        }
        if (OverlayStreamer.readCamera() != null) {
            long deadline = System.nanoTime() + WAIT_NS;
            while (OverlayStreamer.cameraSeq() <= lastSeq && System.nanoTime() < deadline) {
                LockSupport.parkNanos(100_000L);
            }
        } else {
            // No camera from RE4 (menu, loading, old plugin): don't draw faster than needed
            long wait = IDLE_FRAME_NS - (System.nanoTime() - lastFrameNs);
            if (wait > 0) {
                LockSupport.parkNanos(wait);
            }
        }
        lastFrameNs = System.nanoTime();
    }

    /** Render thread, right before Minecraft draws: take RE4's newest camera. */
    public static void onRenderFrame(Minecraft mc) {
        active = false;
        renderedSeq = 0;
        if (!Re4Bridge.overlayActive()) {
            return;
        }
        OverlayStreamer.Re4CameraData camera = OverlayStreamer.readCamera();
        if (camera == null) {
            return;
        }
        lastSeq = camera.seq();
        renderedSeq = camera.seq();
        Vec3 mapped = Re4Terrain.toMinecraft(camera.x(), camera.y(), camera.z());
        if (mapped == null) {
            return;   // the two worlds aren't lined up yet
        }
        position = mapped;
        // Minecraft's yaw: 0 looks along +Z, turning toward -X; pitch is positive looking down
        yaw = (float) Math.toDegrees(Math.atan2(-camera.forwardX(), camera.forwardZ()));
        pitch = (float) -Math.toDegrees(Math.asin(Math.max(-1.0, Math.min(1.0, camera.forwardY()))));
        fov = camera.fov();
        active = true;
    }

    public static boolean active() {
        return active;
    }

    /** The RE4 camera number the current picture is drawn with (0 when none). */
    public static long renderedSeq() {
        return renderedSeq;
    }

    public static Vec3 position() {
        return position;
    }

    public static float yaw() {
        return yaw;
    }

    public static float pitch() {
        return pitch;
    }

    public static double fov() {
        return fov;
    }
}
