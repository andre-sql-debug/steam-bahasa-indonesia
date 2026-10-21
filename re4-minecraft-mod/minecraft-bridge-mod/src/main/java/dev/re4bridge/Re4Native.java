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
import net.minecraft.client.renderer.ItemBlockRenderTypes;
import net.minecraft.client.renderer.LightTexture;
import net.minecraft.client.renderer.MultiBufferSource;
import net.minecraft.client.renderer.RenderType;
import net.minecraft.client.renderer.Sheets;
import net.minecraft.client.renderer.block.BlockRenderDispatcher;
import net.minecraft.client.renderer.block.model.BakedQuad;
import net.minecraft.client.renderer.texture.MissingTextureAtlasSprite;
import net.minecraft.client.renderer.texture.OverlayTexture;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.client.resources.model.BakedModel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.Vec3i;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.util.Mth;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.inventory.InventoryMenu;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.RenderShape;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix3f;
import org.joml.Matrix4f;
import org.joml.Quaternionf;
import org.joml.Vector3f;

import java.io.IOException;
import java.io.InputStream;
import java.lang.ref.WeakReference;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
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
 * <p>
 * The blocks you built go the same way: each kind of block (its model and its own few textures) is written once,
 * and every block RE4 can show is a "part" at the block's corner, under a negative number of its own.
 */
public final class Re4Native {
    private static final String FOLDER = "minecraft";           // under natives/STM, and in RE4 resource paths
    private static final String MATERIAL_NAME = "mc";           // the one material in every part model
    private static final int MAX_TEXTURE_SIZE = 1024;           // pixel-art textures are scaled up to about this
    private static final Pattern TEXTURE = Pattern.compile("texture\\[Optional\\[([a-z0-9_.\\-]+:[a-z0-9_./\\-]+)\\]");
    private static final int MAX_NATIVE_BLOCKS = 400;           // the nearest blocks RE4 shows; farther ones stay Minecraft's
    private static final int MAX_BLOCK_QUADS = 512;
    private static final int MAX_BLOCK_SPRITES = 16;

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
    private static Vec3 frameCam = Vec3.ZERO;        // camera-relative -> Minecraft world
    private static Set<BlockPos> shownBlocks = Set.of();   // built blocks RE4 shows this frame
    private static final StringBuilder frameParts = new StringBuilder();
    private static int framePartCount = 0;
    private static final Set<Integer> nativeEntities = new HashSet<>();   // some part shown by RE4 this frame
    private static final Set<Integer> minecraftDrawn = new HashSet<>();   // some part drawn by Minecraft this frame
    private static MultiBufferSource.BufferSource depthSource = null;
    private static final Map<String, RenderType> depthTypes = new HashMap<>();
    private static RenderType blockDepthType = null;
    // Blocks, render thread. Block models are weak keys like model parts (a resource reload makes new ones)
    private static final Map<BakedModel, Map<BlockState, Export>> blockExports = new WeakHashMap<>();
    private static final Map<Long, BlockPose> blockPoses = new HashMap<>();   // block position -> its pose text
    private static List<BlockPos> sortedFrom = null;   // the block list (and camera block) the nearest-first order is for
    private static BlockPos sortedAt = null;
    private static List<BlockPos> sorted = List.of();
    private static int[] atlasPixels = null;           // the block atlas read back once (width, height, RGBA)
    private static WeakReference<TextureAtlasSprite> atlasEra = new WeakReference<>(null);
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
        shownBlocks = Set.of();
        frameCam = cam;
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

    // ---- the blocks you built ----

    /** A block's pose text, kept while the block, its model and its RE4 position stay the same. */
    private record BlockPose(int export, double x, double y, double z, String text) {
    }

    /**
     * Before the mobs are drawn (render thread): the built blocks RE4 can show itself go into this frame's poses,
     * and the ones RE4 shows are drawn into Minecraft's depth only right away, so a mob behind such a wall is
     * hidden like behind RE4's own. Returns those blocks; Minecraft draws all the others after the mobs, as before.
     */
    public static Set<BlockPos> blocks(BlockGetter level, List<BlockPos> nearby, Vec3 cam, PoseStack poseStack) {
        if (frameOffset == null || nearby.isEmpty()) {
            return Set.of();
        }
        BlockRenderDispatcher blockRenderer = Minecraft.getInstance().getBlockRenderer();
        Set<BlockPos> shown = new HashSet<>();
        int sent = 0;
        for (BlockPos pos : nearestFirst(nearby, cam)) {
            if (sent >= MAX_NATIVE_BLOCKS) {
                break;
            }
            BlockState state = level.getBlockState(pos);
            if (state.isAir()) {
                continue;
            }
            Export export = exportFor(blockRenderer, state);
            Vec3 corner = export == null ? null : Re4Terrain.toRe4(pos.getX(), pos.getY(), pos.getZ());
            if (corner == null) {
                continue;
            }
            frameParts.append(blockPose(pos, export, corner));
            framePartCount++;
            sent++;
            if (acked.contains(export.id())) {
                shown.add(pos);
                poseStack.pushPose();
                poseStack.translate(pos.getX() - cam.x, pos.getY() - cam.y, pos.getZ() - cam.z);
                try {
                    blockRenderer.renderSingleBlock(state, poseStack, BLOCK_DEPTH, LightTexture.FULL_BRIGHT, OverlayTexture.NO_OVERLAY);
                } catch (RuntimeException e) {
                    // RE4 still shows it; only Minecraft's hiding behind it is missing
                }
                poseStack.popPose();
            }
        }
        if (!shown.isEmpty()) {
            flushDepth();
        }
        shownBlocks = shown;
        return shown;
    }

    // The scanned blocks nearest the camera first (only needed past the cap; sorted again when the scan or the
    // camera's block changes, not every frame)
    private static List<BlockPos> nearestFirst(List<BlockPos> blocks, Vec3 cam) {
        if (blocks.size() <= MAX_NATIVE_BLOCKS) {
            return blocks;
        }
        BlockPos at = BlockPos.containing(cam);
        if (blocks != sortedFrom || !at.equals(sortedAt)) {
            List<BlockPos> copy = new ArrayList<>(blocks);
            copy.sort(Comparator.comparingDouble(p -> p.distToCenterSqr(cam)));
            sorted = copy;
            sortedFrom = blocks;
            sortedAt = at;
        }
        return sorted;
    }

    // A built block in the poses: no rotation, full size, at its corner. Its number is negative (entity ids never
    // are) and the same every frame, so RE4 keeps one object on it; the text is kept, so RE4 sees it unchanged
    private static String blockPose(BlockPos pos, Export export, Vec3 corner) {
        long key = pos.asLong();
        BlockPose cached = blockPoses.get(key);
        if (cached != null && cached.export() == export.id() && cached.x() == corner.x && cached.y() == corner.y && cached.z() == corner.z) {
            return cached.text();
        }
        if (blockPoses.size() > 8192) {
            blockPoses.clear();   // blocks long gone
        }
        String text = String.format(Locale.ROOT, "%d,%d,%.4f,%.4f,%.4f,0,0,0,1,1,1,1;", blockId(pos), export.id(), corner.x, corner.y, corner.z);
        blockPoses.put(key, new BlockPose(export.id(), corner.x, corner.y, corner.z, text));
        return text;
    }

    /** The number a built block goes by in the poses: below zero, so never an entity's, and fixed per position. */
    public static long blockId(BlockPos pos) {
        return -1L - (pos.asLong() & Long.MAX_VALUE);
    }

    // Buffers for the blocks RE4 shows: whatever Minecraft asks for, the block textures into depth only (cut out,
    // so the holes in a block's texture stay holes)
    private static final MultiBufferSource BLOCK_DEPTH = renderType -> {
        if (depthSource == null) {
            depthSource = MultiBufferSource.immediate(new ByteBufferBuilder(1 << 16));
        }
        if (blockDepthType == null) {
            blockDepthType = new DepthOnlyType(Sheets.cutoutBlockSheet());
        }
        return depthSource.getBuffer(blockDepthType);
    };

    // A kind of block (one block state) as an RE4 model, made once; null until its files are written, and always
    // for blocks that stay Minecraft's
    private static Export exportFor(BlockRenderDispatcher blockRenderer, BlockState state) {
        BakedModel model = blockRenderer.getBlockModel(state);
        Map<BlockState, Export> forModel = blockExports.computeIfAbsent(model, m -> new HashMap<>());
        if (forModel.containsKey(state)) {
            Export e = forModel.get(state);
            return e != null && ready.containsKey(e.id()) ? e : null;
        }
        forModel.put(state, null);   // being made (or stays Minecraft's)
        if (nativesFolder == null) {
            return null;
        }
        BlockFiles files = blockFiles(state, model);
        if (files == null) {
            return null;
        }
        String key = files.meshName() + "|" + files.texName();
        Export existing = byFiles.get(key);
        if (existing != null) {
            forModel.put(state, existing);
            return ready.containsKey(existing.id()) ? existing : null;
        }
        Export export = new Export(nextId++, FOLDER + "/" + files.meshName() + ".mesh", FOLDER + "/" + files.texName() + ".mdf2");
        byFiles.put(key, export);
        forModel.put(state, export);
        worker.execute(() -> writeExport(export, files.meshName(), files.texName(), null, "block:" + files.texName(),
                files.positions(), files.normals(), files.uvs(), files.image()));
        return null;
    }

    /** A block's model (in its own 0..1 space) and texture image, ready for writeExport. */
    private record BlockFiles(String meshName, String texName, float[] positions, float[] normals, float[] uvs, int[] image) {
    }

    // Render thread: the block's faces as renderSingleBlock draws them, with its own textures cut out of the block
    // atlas. Null when the block stays Minecraft's
    private static BlockFiles blockFiles(BlockState state, BakedModel model) {
        // Plain solid and cut-out blocks only: see-through ones (stained glass, ice, water) and blocks drawn by
        // their own code (chests, banners) stay Minecraft's
        if (state.getRenderShape() != RenderShape.MODEL) {
            return null;
        }
        RenderType layer = ItemBlockRenderTypes.getChunkRenderType(state);
        if (layer != RenderType.solid() && layer != RenderType.cutout() && layer != RenderType.cutoutMipped()) {
            return null;
        }
        // The same random seed as renderSingleBlock, so the same variant of the model
        List<BakedQuad> quads = new ArrayList<>();
        RandomSource random = RandomSource.create();
        for (Direction direction : Direction.values()) {
            random.setSeed(42L);
            quads.addAll(model.getQuads(state, direction, random));
        }
        random.setSeed(42L);
        quads.addAll(model.getQuads(state, null, random));
        if (quads.isEmpty() || quads.size() > MAX_BLOCK_QUADS) {
            return null;
        }
        // Biome-coloured faces (grass, leaves, vines) stay Minecraft's: the RE4 copy can't take the colour
        List<TextureAtlasSprite> sprites = new ArrayList<>();
        for (BakedQuad quad : quads) {
            if (quad.isTinted() || quad.getVertices().length != 32 || !InventoryMenu.BLOCK_ATLAS.equals(quad.getSprite().atlasLocation())) {
                return null;
            }
            // Animated textures (fire, lanterns, campfires, magma, sea lanterns...) stay Minecraft's too: RE4's copy
            // would be one still frame
            if (quad.getSprite().contents().getUniqueFrames().count() > 1) {
                return null;
            }
            if (!sprites.contains(quad.getSprite())) {
                sprites.add(quad.getSprite());
            }
        }
        int[] atlas = blockAtlas();
        if (atlas == null || sprites.size() > MAX_BLOCK_SPRITES) {
            return null;
        }
        int aw = atlas[0], ah = atlas[1];
        // Not the whole atlas (its 16-pixel tiles would blur into each other in RE4): the block's own textures in
        // a row of power-of-two cells
        int cw = 1, ch = 1;
        for (TextureAtlasSprite s : sprites) {
            if (s.getX() + s.contents().width() > aw || s.getY() + s.contents().height() > ah) {
                return null;
            }
            cw = Math.max(cw, s.contents().width());
            ch = Math.max(ch, s.contents().height());
        }
        cw = Mth.smallestEncompassingPowerOfTwo(cw);
        ch = Mth.smallestEncompassingPowerOfTwo(ch);
        int cols = Mth.smallestEncompassingPowerOfTwo(sprites.size());
        int w = cols * cw, h = ch;
        if (w > 4096 || h > 4096) {
            return null;
        }
        int[] image = new int[2 + w * h];
        image[0] = w;
        image[1] = h;
        for (int c = 0; c < cols; c++) {
            // Spare cells repeat the last texture and a smaller texture repeats its edge, so a solid block gets no
            // see-through pixels (and no cut-out material)
            TextureAtlasSprite s = sprites.get(Math.min(c, sprites.size() - 1));
            int sw = s.contents().width(), sh = s.contents().height();
            for (int y = 0; y < ch; y++) {
                for (int x = 0; x < cw; x++) {
                    int ax = s.getX() + Math.min(x, sw - 1), ay = s.getY() + Math.min(y, sh - 1);
                    image[2 + y * w + c * cw + x] = atlas[2 + ay * aw + ax];
                }
            }
        }
        // Each face's atlas coordinates moved into its cell of the small image. A quad's vertices are
        // DefaultVertexFormat.BLOCK, 8 ints each: x y z, colour, u v, light, normal
        GeometryCapture geometry = new GeometryCapture();
        for (BakedQuad quad : quads) {
            int[] v = quad.getVertices();
            TextureAtlasSprite s = quad.getSprite();
            int cell = sprites.indexOf(s);
            Vec3i normal = quad.getDirection().getNormal();
            for (int i = 0; i < 4; i++) {
                int o = i * 8;
                float u = Float.intBitsToFloat(v[o + 4]) * aw - s.getX();
                float vv = Float.intBitsToFloat(v[o + 5]) * ah - s.getY();
                geometry.addVertex(Float.intBitsToFloat(v[o]), Float.intBitsToFloat(v[o + 1]), Float.intBitsToFloat(v[o + 2]))
                        .setUv((cell * cw + u) / w, vv / h)
                        .setNormal(normal.getX(), normal.getY(), normal.getZ());
            }
        }
        float[] positions = geometry.positions();
        float[] uvs = geometry.uvs();
        if (!finite(positions) || !finite(uvs)) {
            return null;
        }
        // Named by content: the same block from another resource pack gets its own files
        String meshName = "m_" + hash(positions, uvs) + "_r" + Re4NativeFiles.FORMAT_REV;
        String texName = "b_" + hashImage(sprites, image) + "_r" + Re4NativeFiles.FORMAT_REV;
        return new BlockFiles(meshName, texName, positions, geometry.normals(), uvs, image);
    }

    private static boolean finite(float[] values) {
        for (float f : values) {
            if (!Float.isFinite(f)) {
                return false;
            }
        }
        return true;
    }

    // Render thread: the block atlas's pixels, read from the graphics card once (again after a resource reload,
    // which makes a new atlas: its missing-texture sprite is then a new object)
    private static int[] blockAtlas() {
        TextureAtlasSprite missing = Minecraft.getInstance().getModelManager().getAtlas(InventoryMenu.BLOCK_ATLAS)
                .getSprite(MissingTextureAtlasSprite.getLocation());
        if (atlasEra.get() != missing) {
            atlasEra = new WeakReference<>(missing);
            atlasPixels = readGpuTexture(InventoryMenu.BLOCK_ATLAS);
            if (atlasPixels == null) {
                Re4Bridge.LOGGER.info("RE4 Bridge: the block atlas can't be read; built blocks stay drawn by Minecraft");
            }
        }
        return atlasPixels;
    }

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

    // A block texture's name: its sprites' names and the pixels themselves
    private static String hashImage(List<TextureAtlasSprite> sprites, int[] image) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            for (TextureAtlasSprite s : sprites) {
                md.update(s.contents().name().toString().getBytes(StandardCharsets.UTF_8));
                md.update((byte) '|');
            }
            ByteBuffer pixels = ByteBuffer.allocate(image.length * 4);
            pixels.asIntBuffer().put(image);
            md.update(pixels.array());
            return hex(md.digest()).substring(0, 16);
        } catch (Exception e) {
            return Integer.toHexString(java.util.Arrays.hashCode(image));
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
        private final ShadowFilter shadowFilter = new ShadowFilter();

        TaggingSource(MultiBufferSource delegate) {
            this.delegate = delegate;
        }

        @Override
        public VertexConsumer getBuffer(RenderType renderType) {
            TaggedConsumer w = wrappers.computeIfAbsent(renderType, TaggingSource::wrapperFor);
            w.delegate = delegate.getBuffer(renderType);
            // Minecraft's round shadow of an entity RE4 shows (drawn after its model, so that is known by now):
            // not on the blocks RE4 shows, RE4 casts the entity's shadow on those itself
            if (w.shadow && currentEntity != null && !shownBlocks.isEmpty() && shownByRe4(currentEntity)) {
                shadowFilter.start(w.delegate);
                return shadowFilter;
            }
            return w;
        }

        private static TaggedConsumer wrapperFor(RenderType renderType) {
            String s = renderType.toString();
            if (s.startsWith("RenderType[entity_shadow")) {
                return new TaggedConsumer(null, false, true);
            }
            // Only the plain opaque entity render types (solid, cutout): see-through layers (slime jelly), glints,
            // outlines, glowing eyes and energy swirls keep Minecraft's drawing. Players are drawn see-through
            // (for their skin's outer layer): for them that one is taken too, cut out like the others
            boolean playersOnly = s.startsWith("RenderType[entity_translucent:");
            if (!playersOnly && !s.startsWith("RenderType[entity_solid") && !s.startsWith("RenderType[entity_cutout")) {
                return new TaggedConsumer(null, false, false);
            }
            Matcher m = TEXTURE.matcher(s);
            return new TaggedConsumer(m.find() ? m.group(1) : null, playersOnly, false);
        }
    }

    // Minecraft's round shadow without its quads on the blocks RE4 shows. The shadow comes as quads of 4 vertices
    // (camera-relative), each lying on the top of one block
    private static final class ShadowFilter implements VertexConsumer {
        private VertexConsumer delegate;
        private final float[] floats = new float[4 * 8];   // x y z u v nx ny nz per vertex
        private final int[] ints = new int[4 * 3];         // colour, overlay, light per vertex
        private int count = 0;

        void start(VertexConsumer delegate) {
            this.delegate = delegate;
            count = 0;
        }

        @Override
        public void addVertex(float x, float y, float z, int color, float u, float v, int overlay, int light, float nx, float ny, float nz) {
            int f = count * 8, i = count * 3;
            floats[f] = x;
            floats[f + 1] = y;
            floats[f + 2] = z;
            floats[f + 3] = u;
            floats[f + 4] = v;
            floats[f + 5] = nx;
            floats[f + 6] = ny;
            floats[f + 7] = nz;
            ints[i] = color;
            ints[i + 1] = overlay;
            ints[i + 2] = light;
            if (++count < 4) {
                return;
            }
            count = 0;
            // The block the quad lies on: just under the quad's middle
            BlockPos under = BlockPos.containing(
                    (floats[0] + floats[8] + floats[16] + floats[24]) / 4.0 + frameCam.x,
                    (floats[1] + floats[9] + floats[17] + floats[25]) / 4.0 + frameCam.y - 0.5,
                    (floats[2] + floats[10] + floats[18] + floats[26]) / 4.0 + frameCam.z);
            if (shownBlocks.contains(under)) {
                return;
            }
            for (int k = 0; k < 4; k++) {
                int a = k * 8, b = k * 3;
                delegate.addVertex(floats[a], floats[a + 1], floats[a + 2], ints[b], floats[a + 3], floats[a + 4],
                        ints[b + 1], ints[b + 2], floats[a + 5], floats[a + 6], floats[a + 7]);
            }
        }

        // Anything drawn one vertex element at a time goes through as it is
        @Override
        public VertexConsumer addVertex(float x, float y, float z) {
            delegate.addVertex(x, y, z);
            return this;
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

    private static final class TaggedConsumer implements VertexConsumer, Tagged {
        private final String texture;
        private final boolean playersOnly;
        final boolean shadow;   // Minecraft's round shadow under an entity
        VertexConsumer delegate;

        TaggedConsumer(String texture, boolean playersOnly, boolean shadow) {
            this.texture = texture;
            this.playersOnly = playersOnly;
            this.shadow = shadow;
        }

        @Override
        public String texture() {
            return playersOnly && !(currentEntity instanceof Player) ? null : texture;
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
