package dev.re4bridge.mixin;

import dev.re4bridge.Re4Enemies;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.LivingEntity;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

// Hits on the stand-ins of RE4's enemies (Re4Enemies) are counted, and RE4 takes them off the real enemy
@Mixin(LivingEntity.class)
public abstract class LivingEntityMixin {
    @Inject(method = "hurt", at = @At("HEAD"), cancellable = true)
    private void re4bridge$countHitsOnRe4Enemies(DamageSource source, float amount, CallbackInfoReturnable<Boolean> cir) {
        LivingEntity self = (LivingEntity) (Object) this;
        if (self.level().isClientSide()) {
            return;
        }
        if (!Re4Enemies.onHurt(self, source, amount)) {
            cir.setReturnValue(false);
        }
    }
}
