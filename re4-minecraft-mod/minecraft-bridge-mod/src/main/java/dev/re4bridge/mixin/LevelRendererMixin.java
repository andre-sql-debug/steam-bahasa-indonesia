package dev.re4bridge.mixin;

import com.mojang.blaze3d.systems.RenderSystem;
import dev.re4bridge.Re4Bridge;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.LevelRenderer;
import org.lwjgl.opengl.GL11;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// While Minecraft's picture is shown over RE4, skip the Minecraft world (sky, terrain, mobs):
// only the hand, held item and HUD are drawn, on a see-through background
@Mixin(LevelRenderer.class)
public class LevelRendererMixin {
    @Inject(method = "renderLevel", at = @At("HEAD"), cancellable = true)
    private void re4bridge$skipWorld(CallbackInfo ci) {
        if (Re4Bridge.overlayActive()) {
            // Rendering the world normally wipes the last frame; without it, wipe to transparent ourselves
            RenderSystem.clearColor(0.0F, 0.0F, 0.0F, 0.0F);
            RenderSystem.clear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT, Minecraft.ON_OSX);
            ci.cancel();
        }
    }
}
