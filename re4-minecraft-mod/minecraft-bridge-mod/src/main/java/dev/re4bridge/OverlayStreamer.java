package dev.re4bridge;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.platform.GlStateManager;
import net.minecraft.client.Minecraft;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL30;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Path;

/**
 * Copies Minecraft's rendered frame (hand, held item and HUD on a see-through background) into
 * reframework\data\minecraft_overlay.bin, which the re4_minecraft_overlay.dll REFramework plugin
 * draws over RE4. Layout must match overlay_plugin.cpp: a 256-byte header and two picture slots,
 * so RE4 always reads a finished picture while the next one is being written. The plugin also writes
 * RE4's camera of each frame into the header; every picture is tagged with the camera it was drawn with.
 */
public final class OverlayStreamer {
    private static final int MAGIC = 0x434D3452;   // 'R4MC'
    private static final int MAX_WIDTH = 1920;
    private static final int MAX_HEIGHT = 1080;
    private static final int VERSION = 2;
    private static final int HEADER_SIZE = 256;
    private static final int SLOT_SIZE = MAX_WIDTH * MAX_HEIGHT * 4;
    private static final long FILE_SIZE = HEADER_SIZE + 2L * SLOT_SIZE;

    private static final VarHandle INT = MethodHandles.byteBufferViewVarHandle(int[].class, ByteOrder.LITTLE_ENDIAN);
    private static final VarHandle LONG = MethodHandles.byteBufferViewVarHandle(long[].class, ByteOrder.LITTLE_ENDIAN);
    private static final VarHandle FLOAT = MethodHandles.byteBufferViewVarHandle(float[].class, ByteOrder.LITTLE_ENDIAN);
    private static final VarHandle DOUBLE = MethodHandles.byteBufferViewVarHandle(double[].class, ByteOrder.LITTLE_ENDIAN);

    /** RE4's camera of one frame: number, position, forward direction and vertical field of view (degrees). */
    public record Re4CameraData(long seq, double x, double y, double z, float forwardX, float forwardY, float forwardZ, float fov) {
    }

    private static MappedByteBuffer buffer;
    private static boolean failed = false;
    private static int latestSlot = 0;
    private static long frames = 0;

    private OverlayStreamer() {
    }

    public static void open(Path file) {
        if (buffer != null || failed) {
            return;
        }
        try (RandomAccessFile raf = new RandomAccessFile(file.toFile(), "rw")) {
            raf.setLength(FILE_SIZE);
            buffer = raf.getChannel().map(FileChannel.MapMode.READ_WRITE, 0, FILE_SIZE);
            INT.set(buffer, 0, MAGIC);
            INT.set(buffer, 4, VERSION);
            INT.setRelease(buffer, 20, 0);
        } catch (IOException e) {
            failed = true;
            Re4Bridge.LOGGER.warn("RE4 Bridge: could not create {}", file, e);
        }
    }

    /** Tells the RE4 plugin whether to draw Minecraft's picture at all. */
    public static void setActive(boolean active) {
        if (buffer != null) {
            INT.setRelease(buffer, 20, active ? 1 : 0);
        }
    }

    /**
     * Tells the RE4 plugin which input RE4 gets: 0 = none of Minecraft's (Minecraft has the mouse and its
     * movement keys), 1 = the movement keys (RE4 moves Leon: ladders, the boat), 2 = everything (RE4's
     * turn while your character plays Leon in a cutscene).
     */
    public static void setInputToRe4(int mode) {
        if (buffer != null) {
            INT.setRelease(buffer, 32, mode);
        }
    }

    /** Tells the RE4 plugin a Minecraft screen is open: Minecraft gets all keys and the mouse. */
    public static void setScreenOpen(boolean open) {
        if (buffer != null) {
            INT.setRelease(buffer, 36, open ? 1 : 0);
        }
    }

    /** Number of RE4's newest camera, 0 when there is none. */
    public static long cameraSeq() {
        return buffer != null ? (long) LONG.getAcquire(buffer, 48) : 0;
    }

    /** RE4's newest camera, or null when RE4 has none right now (menus, loading) or no plugin writes it. */
    public static Re4CameraData readCamera() {
        if (buffer == null) {
            return null;
        }
        // The plugin writes the number last; read it before and after, so the values all belong to it
        for (int attempt = 0; attempt < 3; attempt++) {
            long seq = (long) LONG.getAcquire(buffer, 48);
            if (seq == 0 || (int) INT.getAcquire(buffer, 40) == 0) {
                return null;
            }
            Re4CameraData data = new Re4CameraData(seq, (double) DOUBLE.get(buffer, 56), (double) DOUBLE.get(buffer, 64),
                    (double) DOUBLE.get(buffer, 72), (float) FLOAT.get(buffer, 80), (float) FLOAT.get(buffer, 84),
                    (float) FLOAT.get(buffer, 88), (float) FLOAT.get(buffer, 44));
            if ((long) LONG.getAcquire(buffer, 48) == seq) {
                return data;
            }
        }
        return null;
    }

    /** Called after Minecraft has drawn its HUD for this frame, drawn with RE4's camera number cameraSeq. */
    public static void capture(Minecraft mc, long cameraSeq) {
        if (buffer == null) {
            return;
        }
        RenderTarget target = mc.getMainRenderTarget();
        int width = target.width;
        int height = target.height;
        if (width <= 0 || height <= 0 || width > MAX_WIDTH || height > MAX_HEIGHT) {
            return;
        }
        int slot = 1 - latestSlot;
        ByteBuffer pixels = buffer.slice(HEADER_SIZE + slot * SLOT_SIZE, width * height * 4);
        GlStateManager._glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, target.frameBufferId);
        GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT, 4);
        GL11.glReadPixels(0, 0, width, height, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, pixels);

        INT.set(buffer, 8, width);
        INT.set(buffer, 12, height);
        LONG.setRelease(buffer, 96 + slot * 8, cameraSeq);
        INT.setRelease(buffer, 16, slot);
        LONG.setRelease(buffer, 24, ++frames);
        latestSlot = slot;
    }
}
