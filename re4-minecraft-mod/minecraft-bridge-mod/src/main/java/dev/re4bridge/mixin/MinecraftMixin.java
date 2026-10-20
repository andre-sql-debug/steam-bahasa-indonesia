package dev.re4bridge.mixin;

import dev.re4bridge.Re4Bridge;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// Runs our code at the end of every client tick (20 times per second)
@Mixin(Minecraft.class)
public class MinecraftMixin {
    @Inject(method = "tick", at = @At("TAIL"))
    private void re4bridge$onTick(CallbackInfo ci) {
        Re4Bridge.onClientTick((Minecraft) (Object) this);
    }
}
