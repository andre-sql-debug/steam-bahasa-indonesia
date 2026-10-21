package dev.re4bridge.mixin;

import dev.re4bridge.Re4Bridge;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.Input;
import net.minecraft.client.player.KeyboardInput;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// While RE4 is in control, Minecraft's movement keys come from RE4 instead of the keyboard
@Mixin(KeyboardInput.class)
public abstract class KeyboardInputMixin extends Input {
    @Inject(method = "tick", at = @At("TAIL"))
    private void re4bridge$useRe4Keys(boolean slowDown, float sneakingSpeedMultiplier, CallbackInfo ci) {
        Re4Bridge.RemoteKeys keys = Re4Bridge.remoteKeys();
        // With a Minecraft screen open (inventory, chat) the player stands still, like in Minecraft
        if (keys == null || Minecraft.getInstance().screen != null) {
            return;
        }
        this.up = keys.forward;
        this.down = keys.back;
        this.left = keys.left;
        this.right = keys.right;
        this.jumping = keys.jump;
        this.shiftKeyDown = keys.sneak;

        // Same math as vanilla KeyboardInput
        this.forwardImpulse = this.up == this.down ? 0.0F : (this.up ? 1.0F : -1.0F);
        this.leftImpulse = this.left == this.right ? 0.0F : (this.left ? 1.0F : -1.0F);
        if (slowDown) {
            this.leftImpulse *= sneakingSpeedMultiplier;
            this.forwardImpulse *= sneakingSpeedMultiplier;
        }
    }
}
