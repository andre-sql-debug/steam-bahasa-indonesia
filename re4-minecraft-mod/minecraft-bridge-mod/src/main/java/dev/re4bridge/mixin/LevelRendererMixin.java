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
import net.minecraft.client.renderer.block.BlockRenderDispatcher;
import net.minecraft.client.renderer.entity.EntityRenderDispatcher;
import net.minecraft.client.renderer.texture.OverlayTexture;
import net.minecraft.core.BlockPos;
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
            this.entityRenderDispatcher.render(entity, x, y, z, yaw, partialTick, poseStack, buffers, LightTexture.FULL_BRIGHT);
        }
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
