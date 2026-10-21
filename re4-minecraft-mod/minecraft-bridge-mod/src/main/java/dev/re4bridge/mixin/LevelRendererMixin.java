package dev.re4bridge.mixin;

import com.mojang.blaze3d.platform.Lighting;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.vertex.PoseStack;
import dev.re4bridge.Re4Bridge;
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

// While Minecraft's picture is shown over RE4, skip the Minecraft world (sky, terrain, mobs):
// only the hand, held item and HUD are drawn, on a see-through background. In third person (F5)
// the player's own model is drawn too, so RE4 shows the Minecraft character instead of Leon.
@Mixin(LevelRenderer.class)
public class LevelRendererMixin {
    @Shadow @Final private EntityRenderDispatcher entityRenderDispatcher;
    @Shadow @Final private RenderBuffers renderBuffers;
    @Shadow private ClientLevel level;

    @Inject(method = "renderLevel", at = @At("HEAD"), cancellable = true)
    private void re4bridge$skipWorld(DeltaTracker deltaTracker, boolean renderBlockOutline, Camera camera,
                                     GameRenderer gameRenderer, LightTexture lightTexture, Matrix4f frustumMatrix,
                                     Matrix4f projectionMatrix, CallbackInfo ci) {
        if (Re4Bridge.overlayActive()) {
            // Rendering the world normally wipes the last frame; without it, wipe to transparent ourselves
            RenderSystem.clearColor(0.0F, 0.0F, 0.0F, 0.0F);
            RenderSystem.clear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT, Minecraft.ON_OSX);
            if (camera.isDetached() && camera.getEntity() != null && this.level != null) {
                re4bridge$renderOwnPlayer(deltaTracker, camera, frustumMatrix);
            }
            ci.cancel();
        }
    }

    // The same steps renderLevel takes for one entity, for just the camera's own player
    private void re4bridge$renderOwnPlayer(DeltaTracker deltaTracker, Camera camera, Matrix4f frustumMatrix) {
        Entity entity = camera.getEntity();
        float partialTick = deltaTracker.getGameTimeDeltaPartialTick(!this.level.tickRateManager().isEntityFrozen(entity));
        this.entityRenderDispatcher.prepare(this.level, camera, null);
        Lighting.setupLevel();
        FogRenderer.setupNoFog();

        Matrix4fStack modelView = RenderSystem.getModelViewStack();
        modelView.pushMatrix();
        modelView.mul(frustumMatrix);
        RenderSystem.applyModelViewMatrix();

        Vec3 cam = camera.getPosition();
        double x = Mth.lerp(partialTick, entity.xOld, entity.getX()) - cam.x;
        double y = Mth.lerp(partialTick, entity.yOld, entity.getY()) - cam.y;
        double z = Mth.lerp(partialTick, entity.zOld, entity.getZ()) - cam.z;
        float yaw = Mth.lerp(partialTick, entity.yRotO, entity.getYRot());
        PoseStack poseStack = new PoseStack();
        MultiBufferSource.BufferSource buffers = this.renderBuffers.bufferSource();
        // Full brightness: the player stands high in Minecraft's sky, and RE4 does the scene's lighting
        this.entityRenderDispatcher.render(entity, x, y, z, yaw, partialTick, poseStack, buffers, LightTexture.FULL_BRIGHT);
        buffers.endBatch();

        modelView.popMatrix();
        RenderSystem.applyModelViewMatrix();
    }
}
