package dev.re4bridge.mixin;

import dev.re4bridge.Re4Terrain;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.Mob;
import net.minecraft.world.entity.ai.navigation.GroundPathNavigation;
import net.minecraft.world.entity.ai.navigation.PathNavigation;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.pathfinder.Node;
import net.minecraft.world.level.pathfinder.Path;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.util.ArrayList;
import java.util.List;

// Minecraft's pathfinding only knows real blocks: on RE4's ground (no blocks under the mob) it would look
// for the real ground far below and give up. There the mob walks straight at its target instead
// (Minecraft physics still stops it at RE4's walls and lets it step up), so golems and wolves reach
// RE4's enemies and follow you. Mobs on real blocks keep Minecraft's own pathfinding.
@Mixin(GroundPathNavigation.class)
public abstract class GroundPathNavigationMixin extends PathNavigation {
    protected GroundPathNavigationMixin(Mob mob, Level level) {
        super(mob, level);
    }

    @Inject(method = "createPath(Lnet/minecraft/core/BlockPos;I)Lnet/minecraft/world/level/pathfinder/Path;", at = @At("HEAD"), cancellable = true)
    private void re4bridge$straightOnRe4Ground(BlockPos target, int accuracy, CallbackInfoReturnable<Path> cir) {
        BlockPos start = this.mob.blockPosition();
        if (!Re4Terrain.enforced() || !Re4Terrain.covers(this.mob.getX(), this.mob.getZ())
                || !this.level.getBlockState(start.below()).isAir()) {
            return;
        }
        double range = this.mob.getAttributeValue(net.minecraft.world.entity.ai.attributes.Attributes.FOLLOW_RANGE) + 8.0;
        if (target.distSqr(start) > range * range) {
            cir.setReturnValue(null);
            return;
        }
        List<Node> nodes = new ArrayList<>();
        nodes.add(new Node(start.getX(), start.getY(), start.getZ()));
        nodes.add(new Node(target.getX(), target.getY(), target.getZ()));
        cir.setReturnValue(new Path(nodes, target, true));
    }
}
