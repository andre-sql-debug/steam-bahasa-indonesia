package dev.re4bridge;

import com.google.gson.JsonObject;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * RE4's terrain around Leon, measured by minecraft_terrain.lua with RE4's own physics raycasts, turned into
 * Minecraft collision boxes. Minecraft's player physics walks on these (see EntityMixin), so movement,
 * jumping, stepping up slopes and walls are all real Minecraft physics on RE4's ground.
 *
 * The two worlds are lined up by an anchor: RE4 position = anchorRe4 + (Minecraft position - anchorMc).
 */
public final class Re4Terrain {
    // A terrain snapshot older than this, or not covering the player, freezes Minecraft's player
    private static final long FRESH_MS = 2000;
    private static final double COVERAGE_MARGIN = 2.0;
    private static final double GROUND_THICKNESS = 3.0;
    private static final double WALL_HEIGHT = 2.2;
    private static final double WALL_THICKNESS = 0.1;
    private static final double BUCKET = 2.0;   // spatial hash cell size for lookups

    private record Snapshot(long epoch, double centerX, double centerZ, double radius,
                            Map<Long, List<AABB>> buckets, int boxCount, long receivedMs, List<AABB> occluders) {
    }

    // RE4's floors sit this much lower for hiding things behind them, so feet standing on a floor don't flicker
    private static final double OCCLUDER_SINK = 0.02;

    private static volatile Snapshot snapshot = null;
    private static volatile long anchorEpoch = 0;
    private static volatile double anchorX, anchorY, anchorZ;
    private static volatile boolean enforced = false;

    private Re4Terrain() {
    }

    public static long anchorEpoch() {
        return anchorEpoch;
    }

    public static double[] anchor() {
        return new double[] { anchorX, anchorY, anchorZ };
    }

    /** A new anchor: the Minecraft position that matches Leon's position for this epoch. */
    public static void setAnchor(long epoch, double x, double y, double z) {
        anchorX = x;
        anchorY = y;
        anchorZ = z;
        anchorEpoch = epoch;
        snapshot = null;
    }

    /** Whether terrain rules apply right now (RE4 is in control and an anchor exists). */
    public static void setEnforced(boolean on) {
        enforced = on && anchorEpoch != 0;
    }

    public static boolean enforced() {
        return enforced;
    }

    public static int boxCount() {
        Snapshot s = snapshot;
        return s == null ? 0 : s.boxCount;
    }

    /** True when fresh terrain for the current anchor covers this Minecraft position. */
    public static boolean covers(double x, double z) {
        Snapshot s = snapshot;
        if (s == null || s.epoch != anchorEpoch || System.currentTimeMillis() - s.receivedMs > FRESH_MS) {
            return false;
        }
        double dx = x - s.centerX;
        double dz = z - s.centerZ;
        double r = s.radius - COVERAGE_MARGIN;
        return dx * dx + dz * dz <= r * r;
    }

    /** Collision shapes near an area, for Minecraft's Entity.collide. */
    public static List<VoxelShape> shapesNear(AABB area) {
        List<VoxelShape> out = new ArrayList<>();
        for (AABB box : boxesNear(area)) {
            out.add(Shapes.create(box));
        }
        return out;
    }

    /** RE4's floors and walls as boxes, for hiding Minecraft things that are behind or under them. */
    public static List<AABB> occluders() {
        Snapshot s = snapshot;
        if (s == null || !enforced || System.currentTimeMillis() - s.receivedMs() > FRESH_MS * 2) {
            return List.of();
        }
        return s.occluders();
    }

    /** Terrain boxes touching an area. */
    public static List<AABB> boxesNear(AABB area) {
        Snapshot s = snapshot;
        List<AABB> out = new ArrayList<>();
        if (s == null) {
            return out;
        }
        int x0 = (int) Math.floor(area.minX / BUCKET), x1 = (int) Math.floor(area.maxX / BUCKET);
        int z0 = (int) Math.floor(area.minZ / BUCKET), z1 = (int) Math.floor(area.maxZ / BUCKET);
        for (int bx = x0; bx <= x1; bx++) {
            for (int bz = z0; bz <= z1; bz++) {
                List<AABB> boxes = s.buckets.get(key(bx, bz));
                if (boxes == null) {
                    continue;
                }
                for (AABB box : boxes) {
                    // A box spanning several buckets is listed in each of them; add it once
                    if (box.intersects(area) && !out.contains(box)) {
                        out.add(box);
                    }
                }
            }
        }
        return out;
    }

    /** Distance from {@code from} to the first terrain box on the way to {@code to}, or -1 when nothing is hit. */
    public static double clipDistance(Vec3 from, Vec3 to) {
        double best = -1.0;
        AABB area = new AABB(from, to).inflate(0.5);
        for (AABB box : boxesNear(area)) {
            if (box.contains(from)) {
                continue;
            }
            Optional<Vec3> hit = box.clip(from, to);
            if (hit.isPresent()) {
                double d = hit.get().distanceTo(from);
                if (best < 0.0 || d < best) {
                    best = d;
                }
            }
        }
        return best;
    }

    /**
     * Looking at RE4's ground or walls, as a Minecraft block hit: the block just in front of the surface, so
     * blocks are placed and spawn eggs used there like on a real block. Null when no terrain is in the way.
     */
    public static BlockHitResult clipHit(Vec3 from, Vec3 to) {
        List<AABB> boxes = new ArrayList<>();
        for (AABB box : boxesNear(new AABB(from, to).inflate(0.5))) {
            if (!box.contains(from)) {
                boxes.add(box);
            }
        }
        if (boxes.isEmpty()) {
            return null;
        }
        BlockHitResult hit = AABB.clip(boxes, from, to, BlockPos.ZERO);
        if (hit == null) {
            return null;
        }
        Vec3 at = hit.getLocation();
        Direction face = hit.getDirection();
        BlockPos pos = BlockPos.containing(at.x + face.getStepX() * 0.01, at.y + face.getStepY() * 0.01, at.z + face.getStepZ() * 0.01);
        return new BlockHitResult(at, face, pos, false);
    }

    /**
     * When something stands partly inside the terrain (a mob from a spawn egg lands on a whole block, RE4's
     * floor is in between), the height to lift it to; NaN when it is fine.
     */
    public static double liftOutOf(double x, double y, double z, double tolerance) {
        double top = Double.NaN;
        for (AABB box : boxesNear(new AABB(x - 0.01, y, z - 0.01, x + 0.01, y + tolerance, z + 0.01))) {
            if (box.minY < y + 0.001 && box.maxY > y + 0.001 && box.maxY - y <= tolerance && (Double.isNaN(top) || box.maxY > top)) {
                top = box.maxY;
            }
        }
        return top;
    }

    private static long key(int bx, int bz) {
        return ((long) bx << 32) ^ (bz & 0xFFFFFFFFL);
    }

    private static void add(Map<Long, List<AABB>> buckets, AABB box) {
        int x0 = (int) Math.floor(box.minX / BUCKET), x1 = (int) Math.floor(box.maxX / BUCKET);
        int z0 = (int) Math.floor(box.minZ / BUCKET), z1 = (int) Math.floor(box.maxZ / BUCKET);
        for (int bx = x0; bx <= x1; bx++) {
            for (int bz = z0; bz <= z1; bz++) {
                buckets.computeIfAbsent(key(bx, bz), k -> new ArrayList<>()).add(box);
            }
        }
    }

    /**
     * Loads a terrain message from RE4. Cells are "i,k,h,flags;" with i,k the cell index from Leon's
     * anchor position, h the floor height relative to it (or "x" when the raycast found no floor, which is
     * treated as a wall), and flags bit 1 / bit 2 = wall toward the +x / +z neighbor.
     */
    public static boolean load(JsonObject terrain) {
        if (!terrain.has("epoch") || terrain.get("epoch").getAsLong() != anchorEpoch || anchorEpoch == 0) {
            return false;
        }
        double cell = terrain.get("cell").getAsDouble();
        JsonObject anchorRe4 = terrain.getAsJsonObject("anchor_re4");
        JsonObject center = terrain.getAsJsonObject("center");
        double radius = terrain.get("radius").getAsDouble();
        String cells = terrain.get("cells").getAsString();
        if (cell <= 0.05 || cell > 4 || radius <= 0) {
            return false;
        }
        double ax = anchorRe4.get("x").getAsDouble();
        double ay = anchorRe4.get("y").getAsDouble();
        double az = anchorRe4.get("z").getAsDouble();
        double centerHeight = center.get("y").getAsDouble() - ay;

        Map<Long, List<AABB>> buckets = new HashMap<>();
        List<AABB> occluders = new ArrayList<>();   // floors and walls (not the "no floor" columns)
        Map<Long, Double> heights = new HashMap<>();
        int count = 0;
        List<String[]> parsed = new ArrayList<>();
        for (String entry : cells.split(";")) {
            String[] p = entry.split(",");
            if (p.length < 4) {
                continue;
            }
            parsed.add(p);
            if (!p[2].equals("x")) {
                heights.put(key(Integer.parseInt(p[0]), Integer.parseInt(p[1])), Double.parseDouble(p[2]));
            }
        }
        for (String[] p : parsed) {
            int i = Integer.parseInt(p[0]);
            int k = Integer.parseInt(p[1]);
            int flags = Integer.parseInt(p[3]);
            double x0 = anchorX + i * cell;
            double z0 = anchorZ + k * cell;
            if (p[2].equals("x")) {
                // No floor found: block it off instead of letting the player fall into nothing
                add(buckets, new AABB(x0, anchorY + centerHeight - GROUND_THICKNESS, z0,
                        x0 + cell, anchorY + centerHeight + WALL_HEIGHT + 1.0, z0 + cell));
                count++;
                continue;
            }
            double h = Double.parseDouble(p[2]);
            add(buckets, new AABB(x0, anchorY + h - GROUND_THICKNESS, z0, x0 + cell, anchorY + h, z0 + cell));
            occluders.add(new AABB(x0, anchorY + h - GROUND_THICKNESS, z0, x0 + cell, anchorY + h - OCCLUDER_SINK, z0 + cell));
            count++;
            if ((flags & 1) != 0) {
                double hn = heights.getOrDefault(key(i + 1, k), h);
                double xw = x0 + cell;
                AABB wall = new AABB(xw - WALL_THICKNESS, anchorY + Math.min(h, hn), z0,
                        xw + WALL_THICKNESS, anchorY + Math.max(h, hn) + WALL_HEIGHT, z0 + cell);
                add(buckets, wall);
                occluders.add(wall);
                count++;
            }
            if ((flags & 2) != 0) {
                double hn = heights.getOrDefault(key(i, k + 1), h);
                double zw = z0 + cell;
                AABB wall = new AABB(x0, anchorY + Math.min(h, hn), zw - WALL_THICKNESS,
                        x0 + cell, anchorY + Math.max(h, hn) + WALL_HEIGHT, zw + WALL_THICKNESS);
                add(buckets, wall);
                occluders.add(wall);
                count++;
            }
        }
        double cx = anchorX + (center.get("x").getAsDouble() - ax);
        double cz = anchorZ + (center.get("z").getAsDouble() - az);
        snapshot = new Snapshot(anchorEpoch, cx, cz, radius, buckets, count, System.currentTimeMillis(), occluders);
        return true;
    }
}
