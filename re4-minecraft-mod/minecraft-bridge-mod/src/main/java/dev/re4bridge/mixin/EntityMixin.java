package dev.re4bridge.mixin;

import dev.re4bridge.Re4Terrain;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.MoverType;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.VoxelShape;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.util.ArrayList;
import java.util.List;

// The player collides with RE4's terrain (Re4Terrain) on top of normal Minecraft collisions, and is held
// still while no fresh RE4 terrain covers it (so it can't fall through missing ground)
@Mixin(Entity.class)
public abstract class EntityMixin {
    @Redirect(method = "collide", at = @At(value = "INVOKE",
            target = "Lnet/minecraft/world/level/Level;getEntityCollisions(Lnet/minecraft/world/entity/Entity;Lnet/minecraft/world/phys/AABB;)Ljava/util/List;"))
    private List<VoxelShape> re4bridge$addTerrain(Level level, Entity entity, AABB area) {
        List<VoxelShape> shapes = level.getEntityCollisions(entity, area);
        if (!(entity instanceof Player) || !Re4Terrain.enforced()) {
            return shapes;
        }
        List<VoxelShape> combined = new ArrayList<>(shapes);
        combined.addAll(Re4Terrain.shapesNear(area.inflate(1.0)));
        return combined;
    }

    @Inject(method = "move", at = @At("HEAD"), cancellable = true)
    private void re4bridge$holdWithoutTerrain(MoverType type, Vec3 movement, CallbackInfo ci) {
        Entity self = (Entity) (Object) this;
        if (self instanceof Player && Re4Terrain.enforced() && !Re4Terrain.covers(self.getX(), self.getZ())) {
            self.setDeltaMovement(Vec3.ZERO);
            self.resetFallDistance();
            ci.cancel();
        }
    }
}
