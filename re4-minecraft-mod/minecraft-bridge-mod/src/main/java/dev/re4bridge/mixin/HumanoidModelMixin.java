package dev.re4bridge.mixin;

import dev.re4bridge.Re4Puppet;
import net.minecraft.client.model.HumanoidModel;
import net.minecraft.client.model.geom.ModelPart;
import net.minecraft.world.entity.LivingEntity;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// In a cutscene, your character's arms and legs take Leon's angles (from his skeleton in RE4) instead of
// Minecraft's walking animation. The player model copies them onto its sleeves and pants afterwards.
@Mixin(HumanoidModel.class)
public abstract class HumanoidModelMixin<T extends LivingEntity> {
    @Shadow @Final public ModelPart rightArm;
    @Shadow @Final public ModelPart leftArm;
    @Shadow @Final public ModelPart rightLeg;
    @Shadow @Final public ModelPart leftLeg;

    @Inject(method = "setupAnim(Lnet/minecraft/world/entity/LivingEntity;FFFFF)V", at = @At("TAIL"))
    private void re4bridge$leonsPose(T entity, float limbSwing, float limbSwingAmount, float ageInTicks,
                                     float netHeadYaw, float headPitch, CallbackInfo ci) {
        if (!Re4Puppet.isPuppet(entity)) {
            return;
        }
        re4bridge$pose(this.rightArm, Re4Puppet.limb("right_arm"));
        re4bridge$pose(this.leftArm, Re4Puppet.limb("left_arm"));
        re4bridge$pose(this.rightLeg, Re4Puppet.limb("right_leg"));
        re4bridge$pose(this.leftLeg, Re4Puppet.limb("left_leg"));
    }

    private static void re4bridge$pose(ModelPart part, float[] angles) {
        if (angles != null) {
            part.xRot = angles[0];
            part.yRot = 0.0F;
            part.zRot = angles[1];
        }
    }
}
