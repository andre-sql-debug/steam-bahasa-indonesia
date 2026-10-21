package dev.re4bridge.mixin;

import dev.re4bridge.Re4Bridge;
import dev.re4bridge.Re4Camera;
import dev.re4bridge.Re4Input;
import dev.re4bridge.Re4Puppet;
import net.minecraft.client.Camera;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.GameRenderer;
import net.minecraft.client.renderer.LightTexture;
import net.minecraft.client.renderer.entity.EntityRenderDispatcher;
import net.minecraft.world.entity.Entity;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

// After Minecraft has drawn the hand and HUD for this frame, send the picture to RE4
@Mixin(GameRenderer.class)
public class GameRendererMixin {
    // Before the frame: newest cutscene data from RE4 (your character playing Leon), and keys and mouse from
    // the RE4 window for Minecraft's screens and hotkeys
    @Inject(method = "render", at = @At("HEAD"))
    private void re4bridge$readPuppet(CallbackInfo ci) {
        Re4Puppet.onRenderFrame(Minecraft.getInstance());
        Re4Input.onRenderFrame(Minecraft.getInstance());
        Re4Camera.onRenderFrame(Minecraft.getInstance());
    }

    @Inject(method = "render", at = @At("TAIL"))
    private void re4bridge$captureFrame(CallbackInfo ci) {
        Re4Bridge.onFrameRendered(Minecraft.getInstance());
    }

    // Your hand and held item in RE4: fully lit (Minecraft's own world may be at night while RE4's room is lit)
    @Redirect(method = "renderItemInHand", at = @At(value = "INVOKE",
            target = "Lnet/minecraft/client/renderer/entity/EntityRenderDispatcher;getPackedLightCoords(Lnet/minecraft/world/entity/Entity;F)I"))
    private int re4bridge$handLight(EntityRenderDispatcher dispatcher, Entity entity, float partialTick) {
        if (Re4Bridge.overlayActive()) {
            return LightTexture.FULL_BRIGHT;
        }
        return dispatcher.getPackedLightCoords(entity, partialTick);
    }

    // The field of view the world is drawn with (options FOV plus sprinting etc.), so RE4's camera can match;
    // in a cutscene it is RE4's cutscene camera's instead
    @Inject(method = "getFov", at = @At("RETURN"), cancellable = true)
    private void re4bridge$recordFov(Camera camera, float partialTick, boolean useFovSetting, CallbackInfoReturnable<Double> cir) {
        if (!useFovSetting) {
            return;
        }
        if (!Re4Puppet.active()) {
            Re4Bridge.worldFov = cir.getReturnValue();   // RE4's camera takes this (with sprint zoom)
        }
        if (Re4Camera.active()) {
            cir.setReturnValue(Re4Camera.fov());
        } else if (Re4Puppet.hasCamera()) {
            cir.setReturnValue(Re4Puppet.fov());
        }
    }
}
