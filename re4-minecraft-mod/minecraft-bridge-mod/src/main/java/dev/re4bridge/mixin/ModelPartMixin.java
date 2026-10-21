package dev.re4bridge.mixin;

import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.VertexConsumer;
import dev.re4bridge.Re4Native;
import net.minecraft.client.model.geom.ModelPart;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

import java.util.List;

// Real RE4 mobs (Re4Native): where each model part ends up this frame; the parts RE4 shows are drawn into depth only
@Mixin(ModelPart.class)
public abstract class ModelPartMixin {
    @Shadow @Final private List<ModelPart.Cube> cubes;

    @Shadow
    private void compile(PoseStack.Pose pose, VertexConsumer vertexConsumer, int light, int overlay, int color) {
        throw new AssertionError();
    }

    @Redirect(method = "render(Lcom/mojang/blaze3d/vertex/PoseStack;Lcom/mojang/blaze3d/vertex/VertexConsumer;III)V",
            at = @At(value = "INVOKE", target = "Lnet/minecraft/client/model/geom/ModelPart;compile(Lcom/mojang/blaze3d/vertex/PoseStack$Pose;Lcom/mojang/blaze3d/vertex/VertexConsumer;III)V"))
    private void re4bridge$compile(ModelPart self, PoseStack.Pose pose, VertexConsumer consumer, int light, int overlay, int color) {
        VertexConsumer depthOnly = Re4Native.onPartCompile(self, pose, consumer, this.cubes, color);
        if (depthOnly == null) {
            this.compile(pose, consumer, light, overlay, color);
        } else {
            this.compile(pose, depthOnly, light, overlay, color);
            Re4Native.flushDepth();
        }
    }
}
