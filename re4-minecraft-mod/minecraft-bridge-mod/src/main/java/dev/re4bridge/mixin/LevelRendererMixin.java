package dev.re4bridge.mixin;

import com.mojang.blaze3d.platform.Lighting;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.vertex.PoseStack;
import dev.re4bridge.Re4Bridge;
import dev.re4bridge.Re4Enemies;
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
import net.minecraft.client.renderer.entity.EntityRenderDispatcher;
import net.minecraft.util.Mth;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix4f;
import org.joml.Matrix4fStack;
import org.lwjgl.opengl.GL11;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// While Minecraft's picture is shown over RE4, skip the Minecraft world (sky, terrain, blocks): only
// Minecraft's mobs, dropped items, arrows and particles, the hand, held item and HUD are drawn, on a see-through
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
        buffers.endBatch();
        // Particles: crits, arrow trails, sweeps, potion swirls
        Minecraft.getInstance().particleEngine.render(lightTexture, camera, deltaTracker.getGameTimeDeltaPartialTick(false));

        RenderSystem.setShaderColor(1.0F, 1.0F, 1.0F, 1.0F);
        modelView.popMatrix();
        RenderSystem.applyModelViewMatrix();
    }
}
