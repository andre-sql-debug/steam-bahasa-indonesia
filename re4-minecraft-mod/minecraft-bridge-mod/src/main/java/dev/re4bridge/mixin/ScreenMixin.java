package dev.re4bridge.mixin;

import dev.re4bridge.Re4Input;
import net.minecraft.client.gui.GuiGraphics;
import net.minecraft.client.gui.screens.Screen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

// Minecraft's screens used from the RE4 window (Re4Input): Shift/Ctrl/Alt held in RE4 count (shift-click
// moves a whole stack), and the mouse cursor is drawn into the picture
@Mixin(Screen.class)
public abstract class ScreenMixin {
    @Inject(method = "hasShiftDown", at = @At("HEAD"), cancellable = true)
    private static void re4bridge$shift(CallbackInfoReturnable<Boolean> cir) {
        if (Re4Input.shiftDown()) {
            cir.setReturnValue(true);
        }
    }

    @Inject(method = "hasControlDown", at = @At("HEAD"), cancellable = true)
    private static void re4bridge$control(CallbackInfoReturnable<Boolean> cir) {
        if (Re4Input.controlDown()) {
            cir.setReturnValue(true);
        }
    }

    @Inject(method = "hasAltDown", at = @At("HEAD"), cancellable = true)
    private static void re4bridge$alt(CallbackInfoReturnable<Boolean> cir) {
        if (Re4Input.altDown()) {
            cir.setReturnValue(true);
        }
    }

    @Inject(method = "renderWithTooltip", at = @At("TAIL"))
    private void re4bridge$cursor(GuiGraphics graphics, int mouseX, int mouseY, float partialTick, CallbackInfo ci) {
        Re4Input.drawCursor(graphics, mouseX, mouseY);
    }
}
