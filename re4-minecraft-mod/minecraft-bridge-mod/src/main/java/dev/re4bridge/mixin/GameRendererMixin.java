package dev.re4bridge.mixin;

import dev.re4bridge.Re4Bridge;
import dev.re4bridge.Re4Puppet;
import net.minecraft.client.Camera;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.GameRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

// After Minecraft has drawn the hand and HUD for this frame, send the picture to RE4
@Mixin(GameRenderer.class)
public class GameRendererMixin {
    // Before the frame: newest cutscene data from RE4 (your character playing Leon)
    @Inject(method = "render", at = @At("HEAD"))
    private void re4bridge$readPuppet(CallbackInfo ci) {
        Re4Puppet.onRenderFrame(Minecraft.getInstance());
    }

    @Inject(method = "render", at = @At("TAIL"))
    private void re4bridge$captureFrame(CallbackInfo ci) {
        Re4Bridge.onFrameRendered(Minecraft.getInstance());
    }

    // The field of view the world is drawn with (options FOV plus sprinting etc.), so RE4's camera can match;
    // in a cutscene it is RE4's cutscene camera's instead
    @Inject(method = "getFov", at = @At("RETURN"), cancellable = true)
    private void re4bridge$recordFov(Camera camera, float partialTick, boolean useFovSetting, CallbackInfoReturnable<Double> cir) {
        if (!useFovSetting) {
            return;
        }
        if (Re4Puppet.hasCamera()) {
            cir.setReturnValue(Re4Puppet.fov());
        } else {
            Re4Bridge.worldFov = cir.getReturnValue();
        }
    }
}
