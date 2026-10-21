package dev.re4bridge.mixin;

import com.mojang.blaze3d.platform.InputConstants;
import dev.re4bridge.Re4Input;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

// Shift/Ctrl/Alt held in the RE4 window count for Minecraft's direct key checks too (inventories ask the
// window itself whether Shift is down: shift-click moves a whole stack)
@Mixin(InputConstants.class)
public abstract class InputConstantsMixin {
    @Inject(method = "isKeyDown", at = @At("HEAD"), cancellable = true)
    private static void re4bridge$re4Modifiers(long window, int key, CallbackInfoReturnable<Boolean> cir) {
        boolean held = switch (key) {
            case 340, 344 -> Re4Input.shiftDown();
            case 341, 345 -> Re4Input.controlDown();
            case 342, 346 -> Re4Input.altDown();
            default -> false;
        };
        if (held) {
            cir.setReturnValue(true);
        }
    }
}
