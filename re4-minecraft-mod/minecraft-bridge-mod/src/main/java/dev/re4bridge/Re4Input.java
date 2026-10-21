package dev.re4bridge;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import dev.re4bridge.mixin.MouseHandlerAccessor;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphics;
import net.minecraft.client.gui.screens.Screen;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;

/**
 * Keyboard and mouse from the RE4 window for Minecraft's own screens and hotkeys. The RE4 overlay plugin
 * logs keys (with the characters they type), mouse buttons, wheel and raw mouse movement into
 * minecraft_mouse.json; this replays them into Minecraft through its own handlers, as if they happened in
 * Minecraft's window:
 * <ul>
 * <li>while playing: Minecraft's hotkeys E (inventory, creative menu), T (chat), / (commands), Q (drop),
 * F1-F3, and the mouse wheel (hotbar);</li>
 * <li>while a Minecraft screen is open: every key, typing, a mouse cursor moved by the mouse (drawn into
 * the picture), clicks, dragging and the wheel.</li>
 * </ul>
 */
public final class Re4Input {
    // GLFW key codes of the hotkeys passed on while playing
    private static final Set<Integer> HOTKEYS = Set.of(69, 84, 81, 47, 290, 291, 292);
    private static final int MOD_SHIFT = 1, MOD_CONTROL = 2, MOD_ALT = 4;

    private static Path file;
    private static long fileModified = -1;
    private static boolean primed = false;
    private static long lastX, lastY, lastKeySeq, lastWheel;
    private static final long[] lastPresses = new long[3];
    private static final long[] lastReleases = new long[3];
    private static final boolean[] buttonDown = new boolean[3];
    private static boolean shift, control, alt;
    private static double cursorX = -1, cursorY = -1;
    private static boolean hadScreen = false;
    private static volatile boolean cursorShown = false;

    private Re4Input() {
    }

    public static void init(Path mouseFile) {
        file = mouseFile;
    }

    /** RE4 is driving Minecraft right now (not RE4's turn). */
    private static boolean driving() {
        return Re4Bridge.overlayActive() && !Re4Bridge.re4Turn();
    }

    public static boolean shiftDown() {
        return shift && driving();
    }

    public static boolean controlDown() {
        return control && driving();
    }

    public static boolean altDown() {
        return alt && driving();
    }

    /** Render thread, every frame, before Minecraft draws. */
    public static void onRenderFrame(Minecraft mc) {
        cursorShown = mc.screen != null && driving();
        if (file == null) {
            return;
        }
        JsonObject data;
        try {
            long modified = Files.getLastModifiedTime(file).toMillis();
            if (modified == fileModified) {
                return;
            }
            fileModified = modified;
            data = JsonParser.parseString(Files.readString(file, StandardCharsets.UTF_8)).getAsJsonObject();
        } catch (Exception e) {
            return;   // missing or half-written: next frame
        }
        long x = num(data, "x"), y = num(data, "y"), wheel = num(data, "wheel"), keySeq = num(data, "kseq");
        long[] presses = {num(data, "left_presses"), num(data, "right_presses"), num(data, "middle_presses")};
        long[] releases = {num(data, "left_releases"), num(data, "right_releases"), num(data, "middle_releases")};
        boolean newer = keySeq >= lastKeySeq && presses[0] >= lastPresses[0];

        // First read, the plugin restarted, or RE4 isn't driving Minecraft: just remember where things are
        if (!primed || !newer || !driving() || mc.player == null) {
            primed = true;
            lastX = x;
            lastY = y;
            lastWheel = wheel;
            lastKeySeq = keySeq;
            System.arraycopy(presses, 0, lastPresses, 0, 3);
            System.arraycopy(releases, 0, lastReleases, 0, 3);
            shift = control = alt = false;
            hadScreen = mc.screen != null;
            return;
        }

        long window = mc.getWindow().getWindow();
        replayKeys(mc, window, data.getAsJsonArray("kev"));
        lastKeySeq = keySeq;

        MouseHandlerAccessor mouse = (MouseHandlerAccessor) mc.mouseHandler;
        long dx = x - lastX, dy = y - lastY, dWheel = wheel - lastWheel;
        lastX = x;
        lastY = y;
        lastWheel = wheel;

        Screen screen = mc.screen;
        if (screen != null) {
            int width = mc.getWindow().getScreenWidth(), height = mc.getWindow().getScreenHeight();
            if (!hadScreen || cursorX < 0) {
                cursorX = width / 2.0;
                cursorY = height / 2.0;
                mouse.re4bridge$setXpos(cursorX);
                mouse.re4bridge$setYpos(cursorY);
            }
            // Raw mouse counts are about one RE4 pixel each; Minecraft's window is smaller than RE4's screen
            double scale = Re4Bridge.re4ScreenWidth() > 0 ? (double) width / Re4Bridge.re4ScreenWidth() : 0.5;
            if (dx != 0 || dy != 0) {
                double oldX = cursorX, oldY = cursorY;
                cursorX = Math.max(0, Math.min(width - 1, cursorX + dx * scale));
                cursorY = Math.max(0, Math.min(height - 1, cursorY + dy * scale));
                mouse.re4bridge$setXpos(cursorX);
                mouse.re4bridge$setYpos(cursorY);
                moved(mc, screen, cursorX - oldX, cursorY - oldY);
            }
            for (int button = 0; button < 3; button++) {
                long newPresses = presses[button] - lastPresses[button];
                long newReleases = releases[button] - lastReleases[button];
                // A quick click can press and release between two reads: press first, then release
                while (newPresses > 0 || newReleases > 0) {
                    if (newPresses > 0 && (!buttonDown[button] || newReleases == 0)) {
                        mouse.re4bridge$onPress(window, button, 1, mods());
                        buttonDown[button] = true;
                        newPresses--;
                    } else if (newReleases > 0) {
                        mouse.re4bridge$onPress(window, button, 0, mods());
                        buttonDown[button] = false;
                        newReleases--;
                    } else {
                        break;
                    }
                }
            }
            if (dWheel != 0) {
                mouse.re4bridge$onScroll(window, 0.0, dWheel / 120.0);
            }
        } else {
            buttonDown[0] = buttonDown[1] = buttonDown[2] = false;
            cursorX = -1;
            // While playing, the wheel scrolls the hotbar like in Minecraft
            if (dWheel != 0) {
                mouse.re4bridge$onScroll(window, 0.0, dWheel / 120.0);
            }
        }
        System.arraycopy(presses, 0, lastPresses, 0, 3);
        System.arraycopy(releases, 0, lastReleases, 0, 3);
        hadScreen = mc.screen != null;
    }

    // Minecraft only tells a screen about mouse movement while its window has focus; do it here
    private static void moved(Minecraft mc, Screen screen, double dxPixels, double dyPixels) {
        double toGuiX = (double) mc.getWindow().getGuiScaledWidth() / mc.getWindow().getScreenWidth();
        double toGuiY = (double) mc.getWindow().getGuiScaledHeight() / mc.getWindow().getScreenHeight();
        double gx = cursorX * toGuiX, gy = cursorY * toGuiY;
        try {
            screen.mouseMoved(gx, gy);
            for (int button = 0; button < 3; button++) {
                if (buttonDown[button]) {
                    screen.mouseDragged(gx, gy, button, dxPixels * toGuiX, dyPixels * toGuiY);
                    break;
                }
            }
            screen.afterMouseMove();
        } catch (RuntimeException e) {
            Re4Bridge.LOGGER.warn("RE4 Bridge: screen mouse event failed", e);
        }
    }

    private static void replayKeys(Minecraft mc, long window, JsonArray events) {
        if (events == null) {
            return;
        }
        for (JsonElement element : events) {
            JsonArray e = element.getAsJsonArray();
            long seq = e.get(0).getAsLong();
            if (seq <= lastKeySeq) {
                continue;
            }
            int kind = e.get(1).getAsInt();
            int code = e.get(2).getAsInt();
            if (kind == 2) {
                // A typed character: only screens take text (chat, creative search, signs...)
                Screen screen = mc.screen;
                if (screen != null) {
                    try {
                        screen.charTyped((char) code, mods());
                    } catch (RuntimeException ex) {
                        Re4Bridge.LOGGER.warn("RE4 Bridge: typing failed", ex);
                    }
                }
                continue;
            }
            boolean down = kind != 0;
            trackModifier(code, down);
            int key = glfwKey(code);
            if (key < 0) {
                continue;
            }
            if (mc.screen != null || HOTKEYS.contains(key)) {
                int action = kind == 0 ? 0 : (kind == 3 ? 2 : 1);   // GLFW release / press / repeat
                mc.keyboardHandler.keyPress(window, key, 0, action, mods());
            }
        }
    }

    private static void trackModifier(int vk, boolean down) {
        switch (vk) {
            case 0x10, 0xA0, 0xA1 -> shift = down;
            case 0x11, 0xA2, 0xA3 -> control = down;
            case 0x12, 0xA4, 0xA5 -> alt = down;
            default -> {
            }
        }
    }

    private static int mods() {
        return (shift ? MOD_SHIFT : 0) | (control ? MOD_CONTROL : 0) | (alt ? MOD_ALT : 0);
    }

    /** Windows virtual key to GLFW key code, or -1. */
    static int glfwKey(int vk) {
        if ((vk >= 0x30 && vk <= 0x39) || (vk >= 0x41 && vk <= 0x5A)) {
            return vk;   // digits and letters are the same
        }
        if (vk >= 0x70 && vk <= 0x7B) {
            return 290 + (vk - 0x70);   // F1-F12
        }
        if (vk >= 0x60 && vk <= 0x69) {
            return 320 + (vk - 0x60);   // keypad 0-9
        }
        return switch (vk) {
            case 0x20 -> 32;     // space
            case 0x0D -> 257;    // enter
            case 0x1B -> 256;    // escape
            case 0x08 -> 259;    // backspace
            case 0x09 -> 258;    // tab
            case 0x2D -> 260;    // insert
            case 0x2E -> 261;    // delete
            case 0x27 -> 262;    // right
            case 0x25 -> 263;    // left
            case 0x28 -> 264;    // down
            case 0x26 -> 265;    // up
            case 0x21 -> 266;    // page up
            case 0x22 -> 267;    // page down
            case 0x24 -> 268;    // home
            case 0x23 -> 269;    // end
            case 0x14 -> 280;    // caps lock
            case 0x10, 0xA0 -> 340;   // left shift
            case 0x11, 0xA2 -> 341;   // left control
            case 0x12, 0xA4 -> 342;   // left alt
            case 0xA1 -> 344;    // right shift
            case 0xA3 -> 345;    // right control
            case 0xA5 -> 346;    // right alt
            case 0xBF -> 47;     // slash
            case 0xBA -> 59;     // semicolon
            case 0xBB -> 61;     // equal
            case 0xBC -> 44;     // comma
            case 0xBD -> 45;     // minus
            case 0xBE -> 46;     // period
            case 0xC0 -> 96;     // grave accent
            case 0xDB -> 91;     // left bracket
            case 0xDC -> 92;     // backslash
            case 0xDD -> 93;     // right bracket
            case 0xDE -> 39;     // apostrophe
            default -> -1;
        };
    }

    /** A mouse cursor in the picture while a Minecraft screen is open (Minecraft's window has none of its own). */
    public static void drawCursor(GuiGraphics graphics, int x, int y) {
        if (!cursorShown) {
            return;
        }
        graphics.pose().pushPose();
        graphics.pose().translate(0.0F, 0.0F, 500.0F);
        // An arrow: black outline, white inside
        for (int row = 0; row < 11; row++) {
            int width = Math.min(row + 1, 7);
            graphics.fill(x - 1, y + row - 1, x + width + 1, y + row + 1, 0xFF000000);
        }
        for (int row = 0; row < 10; row++) {
            int width = Math.min(row, 6);
            if (width > 0) {
                graphics.fill(x, y + row, x + width, y + row + 1, 0xFFFFFFFF);
            }
        }
        graphics.pose().popPose();
    }

    private static long num(JsonObject data, String key) {
        return data.has(key) ? data.get(key).getAsLong() : 0;
    }
}
