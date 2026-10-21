package dev.re4bridge;

import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.monster.Husk;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.projectile.Projectile;
import net.minecraft.world.phys.Vec3;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * RE4's enemies inside Minecraft: a Husk "stand-in" (not drawn over RE4) follows each RE4 enemy near Leon, so
 * Minecraft mobs fight them (iron golems go after them by themselves, tamed wolves after what you hit).
 * Damage done to a stand-in is added up per enemy and sent back to RE4, which takes it off the real enemy.
 * Stand-ins never die in Minecraft; they disappear when the RE4 enemy dies or goes away.
 */
public final class Re4Enemies {
    public static final String TAG = "re4_enemy";
    private static final double MAX_HEALTH = 1024.0;

    /** One RE4 enemy, at its Minecraft position. */
    public record Target(String key, double x, double y, double z) {
    }

    private static volatile List<Target> targets = List.of();
    // Server thread only
    private static final Map<String, UUID> proxies = new HashMap<>();
    private static int sweepTicks = 0;
    // Written on the server thread, read on the client thread
    private static final Map<UUID, String> keyOf = new ConcurrentHashMap<>();
    private static final Map<String, Float> damageTotals = new ConcurrentHashMap<>();

    private Re4Enemies() {
    }

    /** From RE4: "key,x,y,z;..." in Minecraft coordinates. */
    public static void setTargets(String list) {
        List<Target> parsed = new ArrayList<>();
        if (list != null && !list.isEmpty()) {
            for (String part : list.split(";")) {
                String[] f = part.split(",");
                if (f.length != 4) {
                    continue;
                }
                try {
                    double x = Double.parseDouble(f[1]), y = Double.parseDouble(f[2]), z = Double.parseDouble(f[3]);
                    if (Double.isFinite(x) && Double.isFinite(y) && Double.isFinite(z)) {
                        parsed.add(new Target(f[0], x, y, z));
                    }
                } catch (NumberFormatException ignored) {
                    // a bad entry; skip it
                }
            }
        }
        targets = parsed;
    }

    public static void clearTargets() {
        targets = List.of();
    }

    public static boolean isStandIn(Entity entity) {
        return keyOf.containsKey(entity.getUUID());
    }

    /** Total Minecraft damage per RE4 enemy so far. */
    public static Map<String, Float> damageTotals() {
        return damageTotals;
    }

    /** Called from LivingEntity.hurt: returns false when the hit should be ignored. */
    public static boolean onHurt(Entity entity, DamageSource source, float amount) {
        if (!keyOf.containsKey(entity.getUUID())) {
            return true;
        }
        // The player's arrows are applied by RE4 directly (aimed with RE4's crosshair)
        return !(source.getDirectEntity() instanceof Projectile && source.getEntity() instanceof Player);
    }

    /** Server thread: make the stand-ins match RE4's enemies. */
    public static void update(MinecraftServer server, UUID playerId) {
        ServerPlayer player = server.getPlayerList().getPlayer(playerId);
        if (player == null) {
            return;
        }
        ServerLevel level = player.serverLevel();
        Map<String, Target> wanted = new HashMap<>();
        for (Target t : targets) {
            wanted.put(t.key(), t);
        }

        // Remove stand-ins whose enemy is gone
        proxies.entrySet().removeIf(entry -> {
            if (wanted.containsKey(entry.getKey())) {
                return false;
            }
            Entity old = level.getEntity(entry.getValue());
            if (old != null) {
                old.discard();
            }
            keyOf.remove(entry.getValue());
            return true;
        });

        for (Target t : wanted.values()) {
            UUID id = proxies.get(t.key());
            Entity entity = id != null ? level.getEntity(id) : null;
            if (entity == null || !entity.isAlive()) {
                if (id != null) {
                    keyOf.remove(id);
                }
                entity = spawn(level, t);
                if (entity == null) {
                    continue;
                }
                proxies.put(t.key(), entity.getUUID());
                keyOf.put(entity.getUUID(), t.key());
            }
            entity.teleportTo(t.x(), t.y(), t.z());
            entity.setDeltaMovement(Vec3.ZERO);
            if (entity instanceof Husk husk) {
                // The damage Minecraft really did (after armor and the short pause between hits), then heal
                float lost = (float) MAX_HEALTH - husk.getHealth();
                if (lost > 0.0F && Float.isFinite(lost)) {
                    damageTotals.merge(t.key(), lost, Float::sum);
                }
                husk.setHealth((float) MAX_HEALTH);
                husk.clearFire();
            }
        }

        // Stand-ins left over from an earlier game (saved with the world): remove them
        if (++sweepTicks >= 40) {
            sweepTicks = 0;
            List<Entity> leftovers = new ArrayList<>();
            for (Entity entity : level.getAllEntities()) {
                if (entity.getTags().contains(TAG) && !keyOf.containsKey(entity.getUUID())) {
                    leftovers.add(entity);
                }
            }
            leftovers.forEach(Entity::discard);
        }
    }

    private static Entity spawn(ServerLevel level, Target t) {
        Husk husk = EntityType.HUSK.create(level);
        if (husk == null) {
            return null;
        }
        husk.moveTo(t.x(), t.y(), t.z(), 0.0F, 0.0F);
        husk.addTag(TAG);
        husk.setNoAi(true);
        husk.setSilent(true);
        // Not invisible: mobs only notice invisible targets from 2 blocks away. The RE4 picture skips them.
        husk.setNoGravity(true);
        husk.setCanPickUpLoot(false);
        // RE4's enemies have no Minecraft armor: every point of damage counts
        var armor = husk.getAttribute(Attributes.ARMOR);
        if (armor != null) {
            armor.setBaseValue(0.0);
        }
        var maxHealth = husk.getAttribute(Attributes.MAX_HEALTH);
        if (maxHealth != null) {
            maxHealth.setBaseValue(MAX_HEALTH);
        }
        husk.setHealth((float) MAX_HEALTH);
        level.addFreshEntity(husk);
        return husk;
    }
}
