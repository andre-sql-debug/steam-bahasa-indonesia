package dev.re4bridge.mixin;

import com.mojang.blaze3d.platform.Lighting;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.vertex.BufferBuilder;
import com.mojang.blaze3d.vertex.BufferUploader;
import com.mojang.blaze3d.vertex.DefaultVertexFormat;
import com.mojang.blaze3d.vertex.MeshData;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.Tesselator;
import com.mojang.blaze3d.vertex.VertexFormat;
import dev.re4bridge.Re4Bridge;
import dev.re4bridge.Re4Enemies;
import dev.re4bridge.Re4Native;
import dev.re4bridge.Re4Terrain;
import net.minecraft.client.Camera;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.FogRenderer;
import net.minecraft.client.renderer.GameRenderer;
import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.LightTexture;
import net.minecraft.client.renderer.MultiBufferSource;
import net.minecraft.client.renderer.RenderBuffers;
import net.minecraft.client.renderer.RenderType;
import net.minecraft.client.renderer.block.BlockRenderDispatcher;
import net.minecraft.client.renderer.entity.EntityRenderDispatcher;
import net.minecraft.client.renderer.texture.OverlayTexture;
import com.mojang.blaze3d.vertex.VertexConsumer;
import net.minecraft.core.BlockPos;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.util.FastColor;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.item.PrimedTnt;
import net.minecraft.world.level.block.RenderShape;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.util.Mth;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix4f;
import org.joml.Matrix4fStack;

import java.util.List;
import org.lwjgl.opengl.GL11;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// While Minecraft's picture is shown over RE4, skip the Minecraft world (sky, terrain, blocks): only
// Minecraft's blocks you built, mobs, dropped items, arrows and particles, the hand, held item and HUD are drawn, on a see-through
// background. In third person (F5) the player's own model is drawn too, so RE4 shows the Minecraft
// character instead of Leon. The stand-ins of RE4's enemies are not drawn (RE4 shows the real enemy).
@Mixin(LevelRenderer.class)
public class LevelRendererMixin {
    @Shadow @Final private EntityRenderDispatcher entityRenderDispatcher;
    @Shadow @Final private RenderBuffers renderBuffers;
    @Shadow private ClientLevel level;

    private static final double RENDER_DISTANCE_SQR = 64.0 * 64.0;
    private static final RenderType RE4BRIDGE_SHADOW = RenderType.entityShadow(ResourceLocation.withDefaultNamespace("textures/misc/shadow.png"));
    private static final double SHADOW_MAX_DROP = 2.5;   // no shadow when the floor is farther below than this

    @Inject(method = "renderLevel", at = @At("HEAD"), cancellable = true)
    private void re4bridge$skipWorld(DeltaTracker deltaTracker, boolean renderBlockOutline, Camera camera,
                                     GameRenderer gameRenderer, LightTexture lightTexture, Matrix4f frustumMatrix,
                                     Matrix4f projectionMatrix, CallbackInfo ci) {
        if (Re4Bridge.overlayActive()) {
            // Rendering the world normally wipes the last frame; without it, wipe to transparent ourselves
            RenderSystem.clearColor(0.0F, 0.0F, 0.0F, 0.0F);
            RenderSystem.clear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT, Minecraft.ON_OSX);
            if (camera.getEntity() != null && this.level != null) {
                re4bridge$renderEntities(deltaTracker, camera, frustumMatrix, lightTexture);
            }
            ci.cancel();
        }
    }

    // RE4's floors and walls, invisible, into the depth buffer only: blocks, mobs and your character behind or
    // under them are then hidden like in RE4 (a block sits in the floor instead of floating over it)
    private static void re4bridge$re4Depth(Vec3 cam) {
        List<AABB> boxes = Re4Terrain.occluders();
        if (boxes.isEmpty()) {
            return;
        }
        RenderSystem.setShader(GameRenderer::getPositionShader);
        RenderSystem.colorMask(false, false, false, false);
        RenderSystem.enableDepthTest();
        RenderSystem.depthMask(true);
        RenderSystem.disableCull();
        BufferBuilder builder = Tesselator.getInstance().begin(VertexFormat.Mode.QUADS, DefaultVertexFormat.POSITION);
        for (AABB box : boxes) {
            float x0 = (float) (box.minX - cam.x), y0 = (float) (box.minY - cam.y), z0 = (float) (box.minZ - cam.z);
            float x1 = (float) (box.maxX - cam.x), y1 = (float) (box.maxY - cam.y), z1 = (float) (box.maxZ - cam.z);
            // top, bottom, and the four sides
            builder.addVertex(x0, y1, z0); builder.addVertex(x0, y1, z1); builder.addVertex(x1, y1, z1); builder.addVertex(x1, y1, z0);
            builder.addVertex(x0, y0, z0); builder.addVertex(x1, y0, z0); builder.addVertex(x1, y0, z1); builder.addVertex(x0, y0, z1);
            builder.addVertex(x0, y0, z0); builder.addVertex(x0, y1, z0); builder.addVertex(x1, y1, z0); builder.addVertex(x1, y0, z0);
            builder.addVertex(x0, y0, z1); builder.addVertex(x1, y0, z1); builder.addVertex(x1, y1, z1); builder.addVertex(x0, y1, z1);
            builder.addVertex(x0, y0, z0); builder.addVertex(x0, y0, z1); builder.addVertex(x0, y1, z1); builder.addVertex(x0, y1, z0);
            builder.addVertex(x1, y0, z0); builder.addVertex(x1, y1, z0); builder.addVertex(x1, y1, z1); builder.addVertex(x1, y0, z1);
        }
        MeshData mesh = builder.build();
        if (mesh != null) {
            BufferUploader.drawWithShader(mesh);
        }
        RenderSystem.colorMask(true, true, true, true);
        RenderSystem.enableCull();
    }

    // Minecraft's own shadows fall on Minecraft blocks only; on RE4's floor, draw the same soft round shadow
    // on the floor below (mobs, your character, dropped items and lit TNT), so they stand on it
    private void re4bridge$re4Shadow(Entity entity, double x, double y, double z, Vec3 cam, MultiBufferSource buffers) {
        if (!(entity instanceof LivingEntity || entity instanceof ItemEntity || entity instanceof PrimedTnt)
                || !Minecraft.getInstance().options.entityShadows().get()) {
            return;
        }
        float radius = Mth.clamp(entity.getBbWidth() * 0.85F, 0.15F, 3.0F);
        AABB column = new AABB(x - radius, y - SHADOW_MAX_DROP, z - radius, x + radius, y + 0.25, z + radius);
        double floor = Double.NEGATIVE_INFINITY;
        for (AABB box : Re4Terrain.boxesNear(column)) {
            if (box.maxY <= y + 0.25 && box.minX <= x && box.maxX >= x && box.minZ <= z && box.maxZ >= z) {
                floor = Math.max(floor, box.maxY);
            }
        }
        if (floor == Double.NEGATIVE_INFINITY) {
            return;
        }
        // Standing on a block you built: Minecraft's own shadow is on it already
        BlockPos below = BlockPos.containing(x, y - 0.2, z);
        if (y - floor > 0.05 && !this.level.getBlockState(below).isAir()) {
            return;
        }
        float strength = (float) (0.5 * (1.0 - (y - floor) / SHADOW_MAX_DROP) * (1.0 - entity.distanceToSqr(cam) / RENDER_DISTANCE_SQR));
        if (strength <= 0.02F) {
            return;
        }
        int color = FastColor.ARGB32.color(Mth.floor(Math.min(1.0F, strength) * 255.0F), 255, 255, 255);
        float x0 = (float) (x - radius - cam.x), x1 = (float) (x + radius - cam.x);
        float z0 = (float) (z - radius - cam.z), z1 = (float) (z + radius - cam.z);
        float fy = (float) (floor + 0.015 - cam.y);   // just above RE4's floor (its stand-in is sunk 0.02)
        VertexConsumer consumer = buffers.getBuffer(RE4BRIDGE_SHADOW);
        consumer.addVertex(x0, fy, z0).setColor(color).setUv(0.0F, 0.0F).setOverlay(OverlayTexture.NO_OVERLAY).setLight(LightTexture.FULL_BRIGHT).setNormal(0.0F, 1.0F, 0.0F);
        consumer.addVertex(x0, fy, z1).setColor(color).setUv(0.0F, 1.0F).setOverlay(OverlayTexture.NO_OVERLAY).setLight(LightTexture.FULL_BRIGHT).setNormal(0.0F, 1.0F, 0.0F);
        consumer.addVertex(x1, fy, z1).setColor(color).setUv(1.0F, 1.0F).setOverlay(OverlayTexture.NO_OVERLAY).setLight(LightTexture.FULL_BRIGHT).setNormal(0.0F, 1.0F, 0.0F);
        consumer.addVertex(x1, fy, z0).setColor(color).setUv(1.0F, 0.0F).setOverlay(OverlayTexture.NO_OVERLAY).setLight(LightTexture.FULL_BRIGHT).setNormal(0.0F, 1.0F, 0.0F);
    }

    // The same steps renderLevel takes for its entities, for the ones near the player
    private void re4bridge$renderEntities(DeltaTracker deltaTracker, Camera camera, Matrix4f frustumMatrix, LightTexture lightTexture) {
        Entity cameraEntity = camera.getEntity();
        this.entityRenderDispatcher.prepare(this.level, camera, null);
        Lighting.setupLevel();
        FogRenderer.setupNoFog();

        Matrix4fStack modelView = RenderSystem.getModelViewStack();
        modelView.pushMatrix();
        modelView.mul(frustumMatrix);
        RenderSystem.applyModelViewMatrix();
        // Full light (the player stands high in Minecraft's sky), toned down to sit better in RE4's darker scenes
        float shade = Re4Bridge.characterBrightness();
        RenderSystem.setShaderColor(shade, shade, shade, 1.0F);

        Vec3 cam = camera.getPosition();
        re4bridge$re4Depth(cam);
        PoseStack poseStack = new PoseStack();
        MultiBufferSource.BufferSource buffers = this.renderBuffers.bufferSource();
        // Real RE4 mobs: the parts RE4 shows itself are captured instead of drawn (Re4Native)
        Re4Native.beginFrame(cam);
        MultiBufferSource entityBuffers = Re4Native.wrap(buffers);
        for (Entity entity : this.level.entitiesForRendering()) {
            boolean self = entity == cameraEntity;
            if ((self && !camera.isDetached()) || entity.isInvisible() || Re4Enemies.isStandIn(entity)
                    || entity.distanceToSqr(cam) > RENDER_DISTANCE_SQR) {
                continue;
            }
            float partialTick = deltaTracker.getGameTimeDeltaPartialTick(!this.level.tickRateManager().isEntityFrozen(entity));
            double x = Mth.lerp(partialTick, entity.xOld, entity.getX()) - cam.x;
            double y = Mth.lerp(partialTick, entity.yOld, entity.getY()) - cam.y;
            double z = Mth.lerp(partialTick, entity.zOld, entity.getZ()) - cam.z;
            float yaw = Mth.lerp(partialTick, entity.yRotO, entity.getYRot());
            Re4Native.beginEntity(entity);
            try {
                this.entityRenderDispatcher.render(entity, x, y, z, yaw, partialTick, poseStack, entityBuffers, LightTexture.FULL_BRIGHT);
            } finally {
                Re4Native.endEntity();
            }
            if (!Re4Native.shownByRe4(entity)) {
                re4bridge$re4Shadow(entity, x + cam.x, y + cam.y, z + cam.z, cam, buffers);   // RE4 casts its own
            }
        }
        Re4Native.endFrame();
        // The blocks you built (TNT, glass, chests...), with Minecraft's own models and textures
        BlockRenderDispatcher blockRenderer = Minecraft.getInstance().getBlockRenderer();
        for (BlockPos pos : Re4Bridge.nearbyBlocks()) {
            BlockState state = this.level.getBlockState(pos);
            if (state.isAir() || state.getRenderShape() == RenderShape.INVISIBLE || pos.distToCenterSqr(cam) > RENDER_DISTANCE_SQR) {
                continue;
            }
            poseStack.pushPose();
            poseStack.translate(pos.getX() - cam.x, pos.getY() - cam.y, pos.getZ() - cam.z);
            try {
                blockRenderer.renderSingleBlock(state, poseStack, buffers, LightTexture.FULL_BRIGHT, OverlayTexture.NO_OVERLAY);
            } catch (RuntimeException e) {
                // a block model that can't be drawn on its own: skip it
            }
            poseStack.popPose();
        }
        buffers.endBatch();
        // Particles: crits, arrow trails, sweeps, potion swirls
        Minecraft.getInstance().particleEngine.render(lightTexture, camera, deltaTracker.getGameTimeDeltaPartialTick(false));

        RenderSystem.setShaderColor(1.0F, 1.0F, 1.0F, 1.0F);
        modelView.popMatrix();
        RenderSystem.applyModelViewMatrix();
    }
}
