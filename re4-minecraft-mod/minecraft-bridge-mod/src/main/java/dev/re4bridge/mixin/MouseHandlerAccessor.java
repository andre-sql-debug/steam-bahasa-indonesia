package dev.re4bridge.mixin;

import net.minecraft.client.MouseHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;
import org.spongepowered.asm.mixin.gen.Invoker;

// Minecraft's own mouse handling, for replaying the RE4 window's mouse into Minecraft's screens (Re4Input)
@Mixin(MouseHandler.class)
public interface MouseHandlerAccessor {
    @Accessor("xpos")
    void re4bridge$setXpos(double xpos);

    @Accessor("ypos")
    void re4bridge$setYpos(double ypos);

    @Invoker("onPress")
    void re4bridge$onPress(long window, int button, int action, int mods);

    @Invoker("onScroll")
    void re4bridge$onScroll(long window, double xOffset, double yOffset);
}
