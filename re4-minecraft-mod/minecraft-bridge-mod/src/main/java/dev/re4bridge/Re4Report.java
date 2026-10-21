package dev.re4bridge;

import com.google.gson.JsonObject;
import com.mojang.blaze3d.platform.GlUtil;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.SharedConstants;
import net.minecraft.client.Minecraft;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/**
 * The support zip. When RE4's Minecraft menu asks for one ("report_request" in minecraft_bridge_input.json),
 * everything needed to look into a problem goes into one zip on the Desktop: Minecraft's log, the mod's files
 * in RE4's reframework\data (diagnostics report, settings, status files), REFramework's log and settings, and
 * lists of the installed RE4 scripts, plugins, mob model files and Minecraft mods. The result (where the zip
 * is, or what went wrong) goes back to RE4 in minecraft_bridge.json ("report").
 */
final class Re4Report {
    private static final long MAX_FILE_BYTES = 16L * 1024 * 1024;   // bigger files are cut (logs) or left out
    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH-mm-ss");

    private static Path dataDir;     // RE4\reframework\data
    private static Path inputFile;
    // The last request handled; Long.MIN_VALUE until RE4's input was read once (an old request isn't a new one)
    private static long lastRequest = Long.MIN_VALUE;
    private static long ticks = 0;
    private static volatile JsonObject status = new JsonObject();
    private static final ExecutorService worker = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "RE4 Bridge support zip");
        t.setDaemon(true);
        return t;
    });

    private Re4Report() {
    }

    static void init(Path bridgeFile) {
        dataDir = bridgeFile.getParent();
        inputFile = bridgeFile.resolveSibling("minecraft_bridge_input.json");
    }

    /** For minecraft_bridge.json: {seq, busy, path or error} of the last request. */
    static JsonObject status() {
        return status;
    }

    // Every few ticks (render thread): a new request from RE4's menu starts a zip. Requests are times (they
    // only grow, also across RE4 script resets); 0 = none.
    static void tick(Minecraft mc) {
        if (inputFile == null || ++ticks % 5 != 0) {
            return;
        }
        JsonObject input = Re4Bridge.readJson(inputFile);
        if (input == null) {
            return;
        }
        long request = input.has("report_request") ? input.get("report_request").getAsLong() : 0;
        if (request == 0 || lastRequest == Long.MIN_VALUE || request == lastRequest) {
            lastRequest = request;
            return;
        }
        lastRequest = request;
        String summary = summary(mc);   // (GPU names need the render thread)
        status = result(request, true, null, null);
        worker.execute(() -> build(request, summary));
    }

    private static JsonObject result(long request, boolean busy, String path, String error) {
        JsonObject s = new JsonObject();
        s.addProperty("seq", request);
        s.addProperty("busy", busy);
        if (path != null) {
            s.addProperty("path", path);
        }
        if (error != null) {
            s.addProperty("error", error);
        }
        return s;
    }

    private static void build(long request, String summary) {
        Path folder = reportFolder();
        Path zipFile = folder.resolve("RE4-Minecraft-report-" + LocalDateTime.now().format(STAMP) + ".zip");
        Path temp = zipFile.resolveSibling(zipFile.getFileName() + ".part");
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(temp))) {
            text(zip, "summary.txt", summary);
            Path gameDir = FabricLoader.getInstance().getGameDir();
            file(zip, "minecraft/latest.log", gameDir.resolve("logs").resolve("latest.log"));
            file(zip, "minecraft/re4bridge.txt", FabricLoader.getInstance().getConfigDir().resolve("re4bridge.txt"));
            try (DirectoryStream<Path> files = Files.newDirectoryStream(dataDir, "minecraft_*.json")) {
                for (Path f : files) {
                    file(zip, "re4/reframework/data/" + f.getFileName(), f);
                }
            }
            Path re4 = dataDir.getParent() != null ? dataDir.getParent().getParent() : null;
            StringBuilder lists = new StringBuilder();
            if (re4 != null) {
                file(zip, "re4/re2_framework_log.txt", re4.resolve("re2_framework_log.txt"));
                file(zip, "re4/re2_fw_config.txt", re4.resolve("re2_fw_config.txt"));
                list(lists, re4.resolve("reframework").resolve("autorun"));
                list(lists, re4.resolve("reframework").resolve("plugins"));
                list(lists, re4.resolve("natives").resolve("STM").resolve("minecraft"));
                list(lists, re4);
            }
            list(lists, gameDir.resolve("mods"));
            text(zip, "installed_files.txt", lists.toString());
        } catch (Exception e) {
            try {
                Files.deleteIfExists(temp);
            } catch (IOException ignored) {
                // nothing more to do
            }
            status = result(request, false, null, e.toString());
            Re4Bridge.LOGGER.warn("RE4 Bridge: could not make the support zip", e);
            return;
        }
        try {
            Files.move(temp, zipFile, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            status = result(request, false, null, e.toString());
            return;
        }
        status = result(request, false, zipFile.toAbsolutePath().toString(), null);
        Re4Bridge.LOGGER.info("RE4 Bridge: support zip saved to {}", zipFile.toAbsolutePath());
    }

    // The Desktop (OneDrive's when Windows keeps it there), else RE4's reframework\data
    private static Path reportFolder() {
        Path home = Path.of(System.getProperty("user.home", "."));
        for (Path desktop : new Path[] { home.resolve("OneDrive").resolve("Desktop"), home.resolve("Desktop") }) {
            if (Files.isDirectory(desktop) && Files.isWritable(desktop)) {
                return desktop;
            }
        }
        return dataDir;
    }

    private static String summary(Minecraft mc) {
        StringBuilder s = new StringBuilder();
        s.append("RE4 Bridge mod ").append(FabricLoader.getInstance().getModContainer("re4bridge")
                .map(m -> m.getMetadata().getVersion().getFriendlyString()).orElse("?")).append('\n');
        s.append("Minecraft ").append(SharedConstants.getCurrentVersion().getName()).append('\n');
        s.append("Java ").append(System.getProperty("java.version")).append(" (").append(System.getProperty("java.vendor"))
                .append(")\n");
        s.append("OS ").append(System.getProperty("os.name")).append(' ').append(System.getProperty("os.version"))
                .append(' ').append(System.getProperty("os.arch")).append('\n');
        try {
            s.append("GPU ").append(GlUtil.getRenderer()).append(" / ").append(GlUtil.getVendor()).append(" / OpenGL ")
                    .append(GlUtil.getOpenGLVersion()).append('\n');
        } catch (Exception e) {
            s.append("GPU ?\n");
        }
        s.append("Window ").append(mc.getWindow().getWidth()).append('x').append(mc.getWindow().getHeight()).append('\n');
        s.append("In a world: ").append(mc.player != null).append(", overlay mode: ").append(Re4Bridge.overlayActive())
                .append(", RE4's turn: ").append(Re4Bridge.re4Turn()).append('\n');
        s.append("Game mode: ").append(mc.gameMode != null ? mc.gameMode.getPlayerMode().getName() : "?").append('\n');
        s.append("RE4 data folder: ").append(dataDir).append('\n');
        s.append("Made: ").append(LocalDateTime.now()).append('\n');
        return s.toString();
    }

    private static void text(ZipOutputStream zip, String name, String content) throws IOException {
        zip.putNextEntry(new ZipEntry(name));
        zip.write(content.getBytes(StandardCharsets.UTF_8));
        zip.closeEntry();
    }

    // A file as it is now (its last MAX_FILE_BYTES if bigger: the end of a log matters most)
    private static void file(ZipOutputStream zip, String name, Path path) throws IOException {
        if (!Files.isRegularFile(path)) {
            return;
        }
        long size = Files.size(path);
        zip.putNextEntry(new ZipEntry(name));
        try (InputStream in = Files.newInputStream(path)) {
            if (size > MAX_FILE_BYTES) {
                in.skipNBytes(size - MAX_FILE_BYTES);
            }
            copy(in, zip, MAX_FILE_BYTES);
        }
        zip.closeEntry();
    }

    private static void copy(InputStream in, OutputStream out, long limit) throws IOException {
        byte[] buffer = new byte[64 * 1024];
        long left = limit;
        int n;
        while (left > 0 && (n = in.read(buffer, 0, (int) Math.min(buffer.length, left))) > 0) {
            out.write(buffer, 0, n);
            left -= n;
        }
    }

    // Names, sizes and dates of a folder's files (not the files themselves)
    private static void list(StringBuilder out, Path folder) {
        out.append("== ").append(folder).append('\n');
        if (!Files.isDirectory(folder)) {
            out.append("   (missing)\n");
            return;
        }
        try (DirectoryStream<Path> files = Files.newDirectoryStream(folder)) {
            for (Path f : files) {
                out.append("   ").append(f.getFileName());
                if (Files.isDirectory(f)) {
                    out.append("\\");
                } else {
                    out.append("  ").append(Files.size(f)).append(" bytes  ").append(Files.getLastModifiedTime(f));
                }
                out.append('\n');
            }
        } catch (IOException e) {
            out.append("   (").append(e).append(")\n");
        }
    }
}
