package dev.re4bridge.mixin;

import dev.re4bridge.Re4Enemies;
import dev.re4bridge.Re4Puppet;
import dev.re4bridge.Re4Terrain;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.MoverType;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.HitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.VoxelShape;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.util.ArrayList;
import java.util.List;

// Everything in Minecraft (the player, mobs, dropped items, arrows) collides with RE4's terrain
// (Re4Terrain) on top of normal Minecraft collisions, and is held still while no fresh RE4 terrain covers
// it (so nothing falls through missing ground). The player can also aim at RE4's ground and walls to
// place blocks and use spawn eggs there.
@Mixin(Entity.class)
public abstract class EntityMixin {
    @Redirect(method = "collide", at = @At(value = "INVOKE",
            target = "Lnet/minecraft/world/level/Level;getEntityCollisions(Lnet/minecraft/world/entity/Entity;Lnet/minecraft/world/phys/AABB;)Ljava/util/List;"))
    private List<VoxelShape> re4bridge$addTerrain(Level level, Entity entity, AABB area) {
        List<VoxelShape> shapes = level.getEntityCollisions(entity, area);
        if (!Re4Terrain.enforced() || Re4Enemies.isStandIn(entity)) {
            return shapes;
        }
        List<VoxelShape> combined = new ArrayList<>(shapes);
        combined.addAll(Re4Terrain.shapesNear(area.inflate(1.0)));
        return combined;
    }

    @Inject(method = "move", at = @At("HEAD"), cancellable = true)
    private void re4bridge$holdWithoutTerrain(MoverType type, Vec3 movement, CallbackInfo ci) {
        Entity self = (Entity) (Object) this;
        // In a cutscene your character goes where Leon goes (Minecraft still animates the walking)
        if (Re4Puppet.isPuppet(self)) {
            Vec3 target = Re4Puppet.bodyTarget();
            if (target != null) {
                self.setPos(target);
            }
            float yaw = Re4Puppet.bodyYaw();
            self.setYRot(yaw);
            self.setXRot(0.0F);
            if (self instanceof LivingEntity living) {
                living.yBodyRot = yaw;
                living.yHeadRot = yaw;
            }
            self.setDeltaMovement(Vec3.ZERO);
            self.resetFallDistance();
            ci.cancel();
            return;
        }
        if (!Re4Terrain.enforced() || Re4Enemies.isStandIn(self)) {
            return;
        }
        if (!Re4Terrain.covers(self.getX(), self.getZ())) {
            self.setDeltaMovement(Vec3.ZERO);
            self.resetFallDistance();
            ci.cancel();
            return;
        }
        // Things that ended up partly inside RE4's floor: mobs from spawn eggs (placed on whole blocks), the
        // player after being moved to Leon (Minecraft doesn't collide with a box it is already inside)
        double top = Re4Terrain.liftOutOf(self.getX(), self.getY(), self.getZ(), self instanceof Player ? 0.4 : 1.0);
        if (!Double.isNaN(top)) {
            self.setPos(self.getX(), top, self.getZ());
        }
    }

    // Looking at RE4's ground or a wall counts as looking at a block (Minecraft's crosshair target)
    @Inject(method = "pick", at = @At("RETURN"), cancellable = true)
    private void re4bridge$pickTerrain(double distance, float partialTick, boolean fluids, CallbackInfoReturnable<HitResult> cir) {
        Entity self = (Entity) (Object) this;
        if (!(self instanceof Player) || !Re4Terrain.enforced()) {
            return;
        }
        Vec3 eye = self.getEyePosition(partialTick);
        Vec3 view = self.getViewVector(partialTick);
        BlockHitResult terrain = Re4Terrain.clipHit(eye, eye.add(view.scale(distance)));
        if (terrain == null) {
            return;
        }
        HitResult vanilla = cir.getReturnValue();
        if (vanilla == null || vanilla.getType() == HitResult.Type.MISS
                || terrain.getLocation().distanceToSqr(eye) < vanilla.getLocation().distanceToSqr(eye)) {
            cir.setReturnValue(terrain);
        }
    }
}
