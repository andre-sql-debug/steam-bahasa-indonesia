package dev.re4bridge.mixin;

import dev.re4bridge.Re4Enemies;
import net.minecraft.world.entity.Mob;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// The stand-ins of RE4's enemies (Re4Enemies) stay while their enemy lives: no despawning when far from
// the player, and none on Peaceful (where Minecraft removes every monster at once)
@Mixin(Mob.class)
public abstract class MobMixin {
    @Inject(method = "checkDespawn", at = @At("HEAD"), cancellable = true)
    private void re4bridge$keepStandIns(CallbackInfo ci) {
        if (Re4Enemies.isStandIn((Mob) (Object) this)) {
            ci.cancel();
        }
    }
}
