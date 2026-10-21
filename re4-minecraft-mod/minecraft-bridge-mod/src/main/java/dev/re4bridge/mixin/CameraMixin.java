package dev.re4bridge.mixin;

import dev.re4bridge.Re4Bridge;
import dev.re4bridge.Re4Camera;
import dev.re4bridge.Re4Puppet;
import dev.re4bridge.Re4Terrain;
import net.minecraft.client.Camera;
import net.minecraft.world.phys.Vec3;
import org.joml.Vector3f;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

// The third-person camera (F5) backs away from the player until it hits a block; also stop it at
// RE4's walls and floors, and remember the distance so RE4 puts its camera at the same spot
@Mixin(Camera.class)
public abstract class CameraMixin {
    @Shadow private Vec3 position;
    @Shadow @Final private Vector3f forwards;
    @Shadow private boolean detached;

    @Shadow protected abstract void setPosition(Vec3 position);

    @Shadow protected abstract void setRotation(float yaw, float pitch);

    // Draw from RE4's own camera of this frame (Re4Camera), so Minecraft's things sit exactly in RE4's world.
    // In a cutscene where your character plays Leon, that's RE4's cutscene camera, looking at your character.
    @Inject(method = "setup", at = @At("TAIL"))
    private void re4bridge$re4Camera(CallbackInfo ci) {
        if (Re4Puppet.active()) {
            this.detached = true;
        }
        if (Re4Camera.active()) {
            this.setRotation(Re4Camera.yaw(), Re4Camera.pitch());
            this.setPosition(Re4Camera.position());
        } else if (Re4Puppet.hasCamera()) {
            this.setRotation(Re4Puppet.cameraYaw(), Re4Puppet.cameraPitch());
            this.setPosition(Re4Puppet.cameraPosition());
        }
    }

    @Inject(method = "getMaxZoom", at = @At("RETURN"), cancellable = true)
    private void re4bridge$stopAtRe4Walls(float wanted, CallbackInfoReturnable<Float> cir) {
        float distance = cir.getReturnValue();
        if (Re4Terrain.enforced()) {
            Vec3 back = this.position.add(new Vec3(this.forwards).scale(-distance));
            double hit = Re4Terrain.clipDistance(this.position, back);
            if (hit >= 0.0) {
                // Stay a little in front of the wall so RE4 doesn't show its inside
                distance = (float) Math.max(0.1, Math.min(distance, hit - 0.2));
                cir.setReturnValue(distance);
            }
        }
        Re4Bridge.cameraDistance = distance;
    }
}
