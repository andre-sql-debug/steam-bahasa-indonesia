package dev.re4bridge.mixin;

import dev.re4bridge.Re4Bridge;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// Every client tick (20 times per second): read RE4's input before the player moves,
// and send the result to RE4 after
@Mixin(Minecraft.class)
public class MinecraftMixin {
    @Inject(method = "tick", at = @At("HEAD"))
    private void re4bridge$onTickStart(CallbackInfo ci) {
        Re4Bridge.onClientTickStart((Minecraft) (Object) this);
    }

    @Inject(method = "tick", at = @At("TAIL"))
    private void re4bridge$onTickEnd(CallbackInfo ci) {
        Re4Bridge.onClientTick((Minecraft) (Object) this);
    }
}
