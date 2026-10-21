package dev.re4bridge;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.mojang.blaze3d.platform.NativeImage;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.vertex.ByteBufferBuilder;
import com.mojang.blaze3d.vertex.DefaultVertexFormat;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.VertexConsumer;
import com.mojang.blaze3d.vertex.VertexFormat;
import net.minecraft.client.Minecraft;
import net.minecraft.client.model.geom.ModelPart;
import net.minecraft.client.renderer.MultiBufferSource;
import net.minecraft.client.renderer.RenderType;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix3f;
import org.joml.Matrix4f;
import org.joml.Quaternionf;
import org.joml.Vector3f;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Minecraft's mobs as real RE4 objects (experimental, switched on from RE4's minecraft_native.lua).
 * <p>
 * Every model part of a mob (a few textured cuboids, e.g. an iron golem's head, body, arms and legs) is written once as
 * an RE4 model file with its texture, into RE4's natives\STM\minecraft folder (loaded by REFramework's Loose File
 * Loader), from Minecraft's own model and texture on this PC. Each frame, while Minecraft draws its things for RE4, the
 * parts' positions and rotations are captured (ModelPartMixin) and sent to RE4, which moves a real RE4 object per part:
 * RE4 then lights, shadows and hides them like its own things. A part stops being drawn over RE4's picture only once
 * RE4 says it has that part's object (minecraft_native_status.json), so nothing vanishes from both.
 */
public final class Re4Native {
    private static final String FOLDER = "minecraft";           // under natives/STM, and in RE4 resource paths
    private static final String MATERIAL_NAME = "mc";           // the one material in every part model
    private static final int MAX_TEXTURE_SIZE = 1024;           // pixel-art textures are scaled up to about this
    private static final Pattern TEXTURE = Pattern.compile("texture\\[Optional\\[([a-z0-9_.\\-]+:[a-z0-9_./\\-]+)\\]");

    /** One part model + material written for RE4. */
    public record Export(int id, String mesh, String material) {
    }

    // RE4's side (minecraft_native_status.json)
    private static volatile boolean enabled = false;
    private static volatile Set<Integer> acked = Set.of();
    private static long statusModified = -1;

    private static Path nativesFolder;   // <RE4>/natives/STM/minecraft
    private static Path statusFile, posesFile, assetsFile;
    private static boolean broken = false;
    private static String problem = "";

    // Render thread. Model parts are weak keys: reloaded models (F3+T, resource packs) drop their old parts
    private static final Map<ModelPart, Map<String, Export>> exports = new WeakHashMap<>();
    private static final Map<String, Export> byFiles = new HashMap<>();   // mesh+material -> export (same content)
    private static int nextId = 1;
    private static Entity currentEntity = null;
    private static final Set<ModelPart> entityParts = Collections.newSetFromMap(new IdentityHashMap<>());   // this entity's, sent
    private static Vec3 frameOffset = null;          // camera-relative -> RE4 world
    private static final StringBuilder frameParts = new StringBuilder();
    private static int framePartCount = 0;
    private static final Set<Integer> nativeEntities = new HashSet<>();   // some part shown by RE4 this frame
    private static final Set<Integer> minecraftDrawn = new HashSet<>();   // some part drawn by Minecraft this frame
    private static MultiBufferSource.BufferSource depthSource = null;
    private static final Map<String, RenderType> depthTypes = new HashMap<>();
    private static volatile boolean assetsDirty = false;   // the assets file couldn't be written (RE4 was reading it)
    private static int assetsRetry = 0;
    private static long seq = 0;
    private static boolean sentEmpty = true;
    // Part numbers start at 1 in every Minecraft session: RE4 only uses numbers of the session it loaded
    private static final long SESSION = ProcessHandle.current().pid();

    // Written by the export thread
    private static final Map<Integer, Export> ready = new ConcurrentHashMap<>();
    private static final Set<String> failedTextures = ConcurrentHashMap.newKeySet();
    private static final ExecutorService worker = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "RE4 Bridge model export");
        t.setDaemon(true);
        return t;
    });

    private Re4Native() {
    }

    public static void init(Path bridgeFile) {
        Path data = bridgeFile.getParent();                       // <RE4>/reframework/data
        statusFile = data.resolve("minecraft_native_status.json");
        posesFile = data.resolve("minecraft_native_poses.json");
        assetsFile = data.resolve("minecraft_native_assets.json");
        Path reframework = data.getParent();
        Path game = reframework == null ? null : reframework.getParent();
        if (game == null) {
            broken = true;
            problem = "RE4's folder not found from " + bridgeFile;
            return;
        }
        nativesFolder = game.resolve("natives").resolve("STM").resolve(FOLDER);
    }

    public static boolean enabled() {
        return enabled && !broken;
    }

    public static String problem() {
        return problem;
    }

    /** Client tick: what RE4 asked for and which part objects it has. */
    public static void readStatus() {
        if (statusFile == null) {
            return;
        }
        try {
            if (!Files.exists(statusFile)) {
                enabled = false;
                return;
            }
            long modified = Files.getLastModifiedTime(statusFile).toMillis();
            if (modified == statusModified) {
                // RE4 stopped writing (closed or the script is off): stop after a few seconds
                if (System.currentTimeMillis() - modified > 5000) {
                    enabled = false;
                    acked = Set.of();
                }
                return;
            }
            statusModified = modified;
            JsonObject status = Re4Bridge.readJson(statusFile);
            if (status == null) {
                return;
            }
            enabled = status.has("enabled") && status.get("enabled").getAsBoolean();
            Set<Integer> ids = new HashSet<>();
            boolean ours = status.has("session") && status.get("session").isJsonPrimitive()
                    && status.get("session").getAsLong() == SESSION;
            if (ours && status.has("acked") && status.get("acked").isJsonArray()) {
                for (JsonElement e : status.getAsJsonArray("acked")) {
                    ids.add(e.getAsInt());
                }
            }
            acked = ids;
        } catch (Exception e) {
            enabled = false;
        }
    }

    // ---- per frame (render thread, from LevelRendererMixin) ----

    /** Start of Minecraft's entity drawing for RE4; cam is the camera position everything is drawn relative to. */
    public static void beginFrame(Vec3 cam) {
        frameParts.setLength(0);
        framePartCount = 0;
        nativeEntities.clear();
        minecraftDrawn.clear();
        frameOffset = enabled() ? Re4Terrain.toRe4(cam.x, cam.y, cam.z) : null;
    }

    public static void beginEntity(Entity entity) {
        currentEntity = entity;
        entityParts.clear();
    }

    public static void endEntity() {
        currentEntity = null;
    }

    /**
     * True when RE4 showed this entity this frame and Minecraft drew none of its parts (RE4 casts its shadow; a
     * player whose cape alone is RE4's still gets Minecraft's shadow).
     */
    public static boolean shownByRe4(Entity entity) {
        return nativeEntities.contains(entity.getId()) && !minecraftDrawn.contains(entity.getId());
    }

    /** End of the entity drawing: send the parts' poses to RE4. */
    public static void endFrame() {
        // The part list couldn't be written earlier (RE4 was reading it): try again now and then
        if (assetsDirty && ++assetsRetry % 20 == 0) {
            assetsDirty = false;
            worker.execute(Re4Native::retryAssets);
        }
        if (!enabled()) {
            if (!sentEmpty) {
                writePoses("");   // tell RE4 to hide everything
                sentEmpty = true;
            }
            return;
        }
        if (framePartCount == 0 && sentEmpty) {
            return;
        }
        writePoses(frameParts.toString());
        sentEmpty = framePartCount == 0;
    }

    /** Buffers that remember which RenderType (and so which texture) each part is drawn with. */
    public static MultiBufferSource wrap(MultiBufferSource buffers) {
        if (!enabled()) {
            return buffers;
        }
        return new TaggingSource(buffers);
    }

    /**
     * Called by ModelPartMixin before drawing a part's cuboids. Returns null when Minecraft draws the part as usual,
     * or, when RE4 shows the part itself, a consumer that draws it into Minecraft's depth only: then whatever
     * Minecraft still draws (armour, held items, layers) is hidden behind RE4's part like it would be behind its own.
     * Call {@link #flushDepth()} after drawing into it.
     */
    public static VertexConsumer onPartCompile(ModelPart part, PoseStack.Pose pose, VertexConsumer consumer, List<ModelPart.Cube> cubes, int color) {
        if (currentEntity == null || frameOffset == null || cubes.isEmpty()) {
            return null;
        }
        int entityId = currentEntity.getId();
        // Tinted parts (dyed wool, leather armor) keep Minecraft's drawing: the RE4 copy has no tint
        String texture = color == -1 && consumer instanceof Tagged tagged ? tagged.texture() : null;
        // Texture layers drawn over the same part (villager clothes and badges, golem cracks) stay Minecraft's:
        // only the first texture of each part goes to RE4, the layers are drawn over it at the same depth
        if (texture == null || failedTextures.contains(texture) || !entityParts.add(part)) {
            minecraftDrawn.add(entityId);
            return null;
        }
        Export export = exportFor(part, texture, cubes);
        // RE4 world transform of the part: camera-relative pose moved into RE4's coordinates. The rotation comes from
        // the matrix with its scale divided out (babies, cave spiders and ghasts are scaled), and a mirrored part
        // keeps its mirror in the scale
        Matrix4f m = pose.pose();
        Vector3f t = m.getTranslation(new Vector3f());
        Vector3f s = m.getScale(new Vector3f());
        Matrix3f r = m.get3x3(new Matrix3f());
        if (r.determinant() < 0) {
            s.x = -s.x;
            r.m00 = -r.m00;
            r.m01 = -r.m01;
            r.m02 = -r.m02;
        }
        Quaternionf q = r.getUnnormalizedRotation(new Quaternionf());
        if (export == null || !Float.isFinite(q.x) || !Float.isFinite(t.x) || s.x == 0.0F) {
            minecraftDrawn.add(entityId);
            return null;
        }
        frameParts.append(String.format(Locale.ROOT, "%d,%d,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f;",
                entityId, export.id(),
                frameOffset.x + t.x, frameOffset.y + t.y, frameOffset.z + t.z,
                q.x, q.y, q.z, q.w, s.x, s.y, s.z));
        framePartCount++;
        if (!acked.contains(export.id())) {
            minecraftDrawn.add(entityId);
            return null;
        }
        nativeEntities.add(entityId);
        // Hit: Minecraft also draws its red-flashing copy over RE4's for that moment
        if (currentEntity instanceof net.minecraft.world.entity.LivingEntity living && (living.hurtTime > 0 || living.deathTime > 0)) {
            return null;
        }
        return depthOnly(texture);
    }

    // Depth-only copies of the parts RE4 shows, drawn at once (before Minecraft draws what may be behind them)
    private static VertexConsumer depthOnly(String texture) {
        ResourceLocation location = ResourceLocation.tryParse(texture);
        if (location == null) {
            return NO_DRAW;
        }
        if (depthSource == null) {
            depthSource = MultiBufferSource.immediate(new ByteBufferBuilder(1 << 16));
        }
        RenderType type = depthTypes.computeIfAbsent(texture, t -> new DepthOnlyType(RenderType.entityCutoutNoCull(location)));
        return depthSource.getBuffer(type);
    }

    /** After a part was drawn into {@link #onPartCompile}'s depth-only consumer. */
    public static void flushDepth() {
        if (depthSource != null) {
            depthSource.endBatch();
        }
    }

    /** A cut-out entity render type that writes depth but no colour. */
    private static final class DepthOnlyType extends RenderType {
        DepthOnlyType(RenderType base) {
            super("re4bridge_depth_only", DefaultVertexFormat.NEW_ENTITY, VertexFormat.Mode.QUADS, 1536, false, false,
                    () -> {
                        base.setupRenderState();
                        RenderSystem.colorMask(false, false, false, false);
                    },
                    () -> {
                        RenderSystem.colorMask(true, true, true, true);
                        base.clearRenderState();
                    });
        }
    }

    // Draws nothing (a part RE4 shows whose texture name can't be used for the depth copy)
    private static final VertexConsumer NO_DRAW = new VertexConsumer() {
        @Override
        public VertexConsumer addVertex(float x, float y, float z) {
            return this;
        }

        @Override
        public VertexConsumer setColor(int r, int g, int b, int a) {
            return this;
        }

        @Override
        public VertexConsumer setUv(float u, float v) {
            return this;
        }

        @Override
        public VertexConsumer setUv1(int u, int v) {
            return this;
        }

        @Override
        public VertexConsumer setUv2(int u, int v) {
            return this;
        }

        @Override
        public VertexConsumer setNormal(float x, float y, float z) {
            return this;
        }
    };

    // ---- exports ----

    private static Export exportFor(ModelPart part, String texture, List<ModelPart.Cube> cubes) {
        Map<String, Export> forPart = exports.computeIfAbsent(part, p -> new HashMap<>());
        if (forPart.containsKey(texture)) {
            Export e = forPart.get(texture);
            return e != null && ready.containsKey(e.id()) ? e : null;
        }
        forPart.put(texture, null);   // being made (or failed)
        if (nativesFolder == null) {
            return null;
        }
        // Geometry, in the part's own space (meters), read on the render thread: Minecraft's own cuboid code
        GeometryCapture geometry = new GeometryCapture();
        PoseStack.Pose identity = new PoseStack().last();
        for (ModelPart.Cube cube : cubes) {
            cube.compile(identity, geometry, 0xF000F0, 0, -1);
        }
        if (geometry.count == 0) {
            return null;
        }
        float[] positions = geometry.positions();
        float[] normals = geometry.normals();
        float[] uvs = geometry.uvs();
        String meshName = "m_" + hash(positions, uvs) + "_r" + Re4NativeFiles.FORMAT_REV;
        String texName = "t_" + hashString(texture) + "_r" + Re4NativeFiles.FORMAT_REV;
        String key = meshName + "|" + texName;
        Export existing = byFiles.get(key);
        if (existing != null) {
            forPart.put(texture, existing);
            return ready.containsKey(existing.id()) ? existing : null;
        }
        Export export = new Export(nextId++, FOLDER + "/" + meshName + ".mesh", FOLDER + "/" + texName + ".mdf2");
        byFiles.put(key, export);
        forPart.put(texture, export);
        ResourceLocation location = ResourceLocation.tryParse(texture);
        // Textures made at runtime (player skins) aren't in the resources: read them from the graphics card now
        int[] gpuImage = location != null && Minecraft.getInstance().getResourceManager().getResource(location).isEmpty()
                ? readGpuTexture(location) : null;
        worker.execute(() -> writeExport(export, meshName, texName, location, texture, positions, normals, uvs, gpuImage));
        return null;
    }

    // Export thread: the part's model, its texture and material, then tell RE4 about it
    private static void writeExport(Export export, String meshName, String texName, ResourceLocation location,
                                    String texture, float[] positions, float[] normals, float[] uvs, int[] gpuImage) {
        try {
            Files.createDirectories(nativesFolder);
            Path mesh = nativesFolder.resolve(meshName + ".mesh." + Re4NativeFiles.MESH_VERSION);
            if (!Files.exists(mesh)) {
                writeAtomically(mesh, Re4NativeFiles.mesh(MATERIAL_NAME, positions, normals, uvs));
            }
            // The material is written last, so once it exists its textures do too
            Path mdf = nativesFolder.resolve(texName + ".mdf2." + Re4NativeFiles.MDF_VERSION);
            if (!Files.exists(mdf)) {
                int[] image = gpuImage != null ? gpuImage : readTexture(location);   // width, height, then RGBA pixels
                if (image == null) {
                    failedTextures.add(texture);
                    Re4Bridge.LOGGER.info("RE4 Bridge: texture {} can't be read; that part stays drawn by Minecraft", texture);
                    return;
                }
                Re4NativeFiles.Textures textures = Re4NativeFiles.textures(image, MAX_TEXTURE_SIZE);
                String cutoutName = texName + "_a";
                if (textures.cutout() != null) {
                    writeAtomically(nativesFolder.resolve(cutoutName + ".tex." + Re4NativeFiles.TEX_VERSION), textures.cutout());
                }
                writeAtomically(nativesFolder.resolve(texName + ".tex." + Re4NativeFiles.TEX_VERSION), textures.color());
                writeAtomically(mdf, Re4NativeFiles.material(MATERIAL_NAME, FOLDER + "/" + texName + ".tex",
                        textures.cutout() != null ? FOLDER + "/" + cutoutName + ".tex" : null));
            }
        } catch (Exception e) {
            failedTextures.add(texture);
            problem = "could not write " + meshName + ": " + e;
            Re4Bridge.LOGGER.warn("RE4 Bridge: could not write the RE4 model for {}", texture, e);
            return;
        }
        // The files are complete: tell RE4 (a failure here is only RE4 reading the list right now: retried)
        ready.put(export.id(), export);
        retryAssets();
    }

    private static void retryAssets() {
        try {
            writeAssets();
        } catch (IOException e) {
            assetsDirty = true;
        }
    }

    // RGBA pixels of a texture from Minecraft's resources (mod and resource-pack textures included)
    private static int[] readTexture(ResourceLocation location) {
        if (location == null) {
            return null;
        }
        try {
            Resource resource = Minecraft.getInstance().getResourceManager().getResource(location).orElse(null);
            if (resource == null) {
                return null;   // a texture made at runtime (player skins): not readable here
            }
            try (InputStream in = resource.open(); NativeImage image = NativeImage.read(in)) {
                int w = image.getWidth(), h = image.getHeight();
                int[] out = new int[2 + w * h];
                out[0] = w;
                out[1] = h;
                for (int y = 0; y < h; y++) {
                    for (int x = 0; x < w; x++) {
                        int abgr = image.getPixelRGBA(x, y);   // NativeImage stores ABGR
                        int r = abgr & 0xFF, g = (abgr >> 8) & 0xFF, b = (abgr >> 16) & 0xFF, a = (abgr >>> 24);
                        out[2 + y * w + x] = (r << 24) | (g << 16) | (b << 8) | a;   // RGBA
                    }
                }
                return out;
            }
        } catch (IOException e) {
            return null;
        }
    }

    // Render thread: a loaded texture's pixels straight from OpenGL (width, height, then RGBA)
    private static int[] readGpuTexture(ResourceLocation location) {
        try {
            net.minecraft.client.renderer.texture.AbstractTexture tex = Minecraft.getInstance().getTextureManager().getTexture(location);
            if (tex == null) {
                return null;
            }
            com.mojang.blaze3d.systems.RenderSystem.bindTexture(tex.getId());
            int w = org.lwjgl.opengl.GL11.glGetTexLevelParameteri(org.lwjgl.opengl.GL11.GL_TEXTURE_2D, 0, org.lwjgl.opengl.GL11.GL_TEXTURE_WIDTH);
            int h = org.lwjgl.opengl.GL11.glGetTexLevelParameteri(org.lwjgl.opengl.GL11.GL_TEXTURE_2D, 0, org.lwjgl.opengl.GL11.GL_TEXTURE_HEIGHT);
            if (w <= 0 || h <= 0 || w > 4096 || h > 4096) {
                return null;
            }
            java.nio.ByteBuffer pixels = org.lwjgl.system.MemoryUtil.memAlloc(w * h * 4);
            try {
                org.lwjgl.opengl.GL11.glPixelStorei(org.lwjgl.opengl.GL11.GL_PACK_ALIGNMENT, 1);
                org.lwjgl.opengl.GL11.glGetTexImage(org.lwjgl.opengl.GL11.GL_TEXTURE_2D, 0, org.lwjgl.opengl.GL11.GL_RGBA,
                        org.lwjgl.opengl.GL11.GL_UNSIGNED_BYTE, pixels);
                int[] out = new int[2 + w * h];
                out[0] = w;
                out[1] = h;
                for (int i = 0; i < w * h; i++) {
                    int r = pixels.get(i * 4) & 0xFF, g = pixels.get(i * 4 + 1) & 0xFF;
                    int b = pixels.get(i * 4 + 2) & 0xFF, a = pixels.get(i * 4 + 3) & 0xFF;
                    out[2 + i] = (r << 24) | (g << 16) | (b << 8) | a;
                }
                return out;
            } finally {
                org.lwjgl.system.MemoryUtil.memFree(pixels);
            }
        } catch (Exception e) {
            return null;
        }
    }

    private static synchronized void writeAssets() throws IOException {
        JsonObject root = new JsonObject();
        JsonObject list = new JsonObject();
        for (Export e : ready.values()) {
            JsonObject o = new JsonObject();
            o.addProperty("mesh", e.mesh());
            o.addProperty("material", e.material());
            list.add(Integer.toString(e.id()), o);
        }
        root.add("exports", list);
        root.addProperty("session", SESSION);
        writeAtomically(assetsFile, root.toString().getBytes(StandardCharsets.UTF_8));
    }

    private static void writePoses(String parts) {
        try {
            String json = "{\"seq\":" + (++seq) + ",\"session\":" + SESSION + ",\"parts\":\"" + parts + "\"}";
            writeAtomically(posesFile, json.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            Re4Bridge.warnOnce("could not write the RE4 mob poses", e);
        }
    }

    private static void writeAtomically(Path file, byte[] data) throws IOException {
        Path tmp = file.resolveSibling(file.getFileName() + ".tmp");
        Files.write(tmp, data);
        Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
    }

    private static String hash(float[] a, float[] b) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            for (float f : a) {
                md.update(Float.toString(f).getBytes(StandardCharsets.US_ASCII));
            }
            md.update((byte) '|');
            for (float f : b) {
                md.update(Float.toString(f).getBytes(StandardCharsets.US_ASCII));
            }
            return hex(md.digest()).substring(0, 16);
        } catch (Exception e) {
            return Integer.toHexString(java.util.Arrays.hashCode(a) * 31 + java.util.Arrays.hashCode(b));
        }
    }

    private static String hashString(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            return hex(md.digest(s.getBytes(StandardCharsets.UTF_8))).substring(0, 16);
        } catch (Exception e) {
            return Integer.toHexString(s.hashCode());
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    // ---- helpers ----

    /** A part's cuboids as triangles, both sides (so RE4's face order doesn't matter), from Minecraft's quads. */
    private static final class GeometryCapture implements VertexConsumer {
        private final List<float[]> quadVerts = new ArrayList<>();   // x y z u v nx ny nz per vertex
        private float[] current;
        int count = 0;

        @Override
        public VertexConsumer addVertex(float x, float y, float z) {
            current = new float[] { x, y, z, 0, 0, 0, 1, 0 };
            quadVerts.add(current);
            count++;
            return this;
        }

        @Override
        public VertexConsumer setColor(int r, int g, int b, int a) {
            return this;
        }

        @Override
        public VertexConsumer setUv(float u, float v) {
            if (current != null) {
                current[3] = u;
                current[4] = v;
            }
            return this;
        }

        @Override
        public VertexConsumer setUv1(int u, int v) {
            return this;
        }

        @Override
        public VertexConsumer setUv2(int u, int v) {
            return this;
        }

        @Override
        public VertexConsumer setNormal(float x, float y, float z) {
            if (current != null) {
                current[5] = x;
                current[6] = y;
                current[7] = z;
            }
            return this;
        }

        // Each quad (4 vertices) twice: as is, and turned around with its normal flipped
        private int quads() {
            return quadVerts.size() / 4;
        }

        float[] positions() {
            float[] out = new float[quads() * 8 * 3];
            int o = 0;
            for (int side = 0; side < 2; side++) {
                for (int q = 0; q < quads(); q++) {
                    for (int i = 0; i < 4; i++) {
                        float[] v = quadVerts.get(q * 4 + i);
                        out[o++] = v[0];
                        out[o++] = v[1];
                        out[o++] = v[2];
                    }
                }
            }
            return out;
        }

        float[] normals() {
            float[] out = new float[quads() * 8 * 3];
            int o = 0;
            for (int side = 0; side < 2; side++) {
                float sign = side == 0 ? 1.0F : -1.0F;
                for (int q = 0; q < quads(); q++) {
                    for (int i = 0; i < 4; i++) {
                        float[] v = quadVerts.get(q * 4 + i);
                        out[o++] = v[5] * sign;
                        out[o++] = v[6] * sign;
                        out[o++] = v[7] * sign;
                    }
                }
            }
            return out;
        }

        float[] uvs() {
            float[] out = new float[quads() * 8 * 2];
            int o = 0;
            for (int side = 0; side < 2; side++) {
                for (int q = 0; q < quads(); q++) {
                    for (int i = 0; i < 4; i++) {
                        float[] v = quadVerts.get(q * 4 + i);
                        out[o++] = v[3];
                        out[o++] = v[4];
                    }
                }
            }
            return out;
        }

        /** Triangle indices for positions(): two per quad, the second copy wound the other way. */
        static int[] indices(int quads) {
            int[] out = new int[quads * 2 * 6];
            int o = 0;
            for (int q = 0; q < quads; q++) {
                int b = q * 4;
                out[o++] = b; out[o++] = b + 1; out[o++] = b + 2;
                out[o++] = b; out[o++] = b + 2; out[o++] = b + 3;
            }
            for (int q = 0; q < quads; q++) {
                int b = (quads + q) * 4;
                out[o++] = b; out[o++] = b + 2; out[o++] = b + 1;
                out[o++] = b; out[o++] = b + 3; out[o++] = b + 2;
            }
            return out;
        }
    }

    /** A vertex consumer that knows its RenderType's texture. */
    public interface Tagged {
        String texture();
    }

    private static final class TaggingSource implements MultiBufferSource {
        private final MultiBufferSource delegate;
        private final Map<RenderType, TaggedConsumer> wrappers = new IdentityHashMap<>();

        TaggingSource(MultiBufferSource delegate) {
            this.delegate = delegate;
        }

        @Override
        public VertexConsumer getBuffer(RenderType renderType) {
            TaggedConsumer w = wrappers.computeIfAbsent(renderType, rt -> new TaggedConsumer(textureOf(rt)));
            w.delegate = delegate.getBuffer(renderType);
            return w;
        }

        private static String textureOf(RenderType renderType) {
            String s = renderType.toString();
            // Only the plain opaque entity render types (solid, cutout): see-through layers (slime jelly), glints,
            // outlines, glowing eyes and energy swirls keep Minecraft's drawing
            if (!s.startsWith("RenderType[entity_solid") && !s.startsWith("RenderType[entity_cutout")) {
                return null;
            }
            Matcher m = TEXTURE.matcher(s);
            return m.find() ? m.group(1) : null;
        }
    }

    private static final class TaggedConsumer implements VertexConsumer, Tagged {
        private final String texture;
        VertexConsumer delegate;

        TaggedConsumer(String texture) {
            this.texture = texture;
        }

        @Override
        public String texture() {
            return texture;
        }

        @Override
        public VertexConsumer addVertex(float x, float y, float z) {
            delegate.addVertex(x, y, z);
            return this;
        }

        @Override
        public void addVertex(float x, float y, float z, int color, float u, float v, int overlay, int light, float nx, float ny, float nz) {
            delegate.addVertex(x, y, z, color, u, v, overlay, light, nx, ny, nz);
        }

        @Override
        public VertexConsumer setColor(int r, int g, int b, int a) {
            delegate.setColor(r, g, b, a);
            return this;
        }

        @Override
        public VertexConsumer setUv(float u, float v) {
            delegate.setUv(u, v);
            return this;
        }

        @Override
        public VertexConsumer setUv1(int u, int v) {
            delegate.setUv1(u, v);
            return this;
        }

        @Override
        public VertexConsumer setUv2(int u, int v) {
            delegate.setUv2(u, v);
            return this;
        }

        @Override
        public VertexConsumer setNormal(float x, float y, float z) {
            delegate.setNormal(x, y, z);
            return this;
        }
    }

    /** Triangle indices for a part with this many quads (see GeometryCapture). */
    public static int[] indicesFor(int vertexCount) {
        return GeometryCapture.indices(vertexCount / 8);
    }
}
