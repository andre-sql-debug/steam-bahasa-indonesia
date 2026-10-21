package dev.re4bridge;

import dev.re4bridge.reengine.ReMdfWriter;
import dev.re4bridge.reengine.ReMeshWriter;
import dev.re4bridge.reengine.ReTexWriter;

/**
 * RE4 file contents for Re4Native: a part's model (.mesh), its texture (.tex, plus a cut-out mask when it has
 * see-through pixels) and its material (.mdf2), made with the writers in dev.re4bridge.reengine.
 */
final class Re4NativeFiles {
    static final String MESH_VERSION = Integer.toString(ReMeshWriter.FILE_VERSION);
    static final String TEX_VERSION = Integer.toString(ReTexWriter.FILE_VERSION);
    static final String MDF_VERSION = Integer.toString(ReMdfWriter.FILE_VERSION);
    // Part of every file name: a corrected writer makes new names, so RE4 never keeps an old copy cached
    static final int FORMAT_REV = 3;
    // Mips narrower than this are left out: their row padding differs between tools (RE4 doesn't need them)
    private static final int SMALLEST_MIP = 64;
    // Pixels at least this opaque are drawn (Minecraft's cut-out entity textures are 0 or 255)
    private static final float ALPHA_TEST_REF = 0.5F;

    /** A texture for RE4: the colour map, and the cut-out mask (null when every pixel is opaque). */
    record Textures(byte[] color, byte[] cutout) {
    }

    private Re4NativeFiles() {
    }

    /** positions/normals/uvs as made by Re4Native's geometry capture (both windings already in). */
    static byte[] mesh(String material, float[] positions, float[] normals, float[] uvs) {
        int[] indices = Re4Native.indicesFor(positions.length / 3);
        // The shadow LOD shares the model (like RE4's own meshes that cast shadows), so the mob casts RE4 shadows
        return ReMeshWriter.toBytes(material, positions, normals, uvs, indices, new ReMeshWriter.Options().shadowLod(true));
    }

    /** image: width, height, then RGBA pixels (Re4Native's texture readers). Scaled up to about maxSize, sharply. */
    static Textures textures(int[] image, int maxSize) {
        int w = image[0], h = image[1];
        int[] argb = new int[w * h];
        for (int i = 0; i < w * h; i++) {
            int rgba = image[2 + i];
            argb[i] = ((rgba & 0xFF) << 24) | (rgba >>> 8);
        }
        // Minecraft's 16-64 pixel textures would look blurred with RE4's filtering: make each pixel a block
        int factor = ReTexWriter.upscaleFactor(w, h, maxSize, 8);
        if (factor > 1) {
            argb = ReTexWriter.upscaleNearest(argb, w, h, factor);
            w *= factor;
            h *= factor;
        }
        byte[] color = ReTexWriter.toBytes(argb, w, h, ReTexWriter.Kind.BASE_DIELECTRIC, SMALLEST_MIP);
        byte[] cutout = ReTexWriter.hasTransparency(argb)
                ? ReTexWriter.toBytes(ReTexWriter.alphaToAtos(argb), w, h, ReTexWriter.Kind.LINEAR_DATA, SMALLEST_MIP)
                : null;
        return new Textures(color, cutout);
    }

    /** The material: RE4's standard environment material with our texture (and cut-out mask, if any). */
    static byte[] material(String material, String texturePath, String cutoutPath) {
        ReMdfWriter.Material m = new ReMdfWriter.Material(material, texturePath);
        if (cutoutPath != null) {
            m.alphaTest(cutoutPath, ALPHA_TEST_REF);
        }
        return ReMdfWriter.toBytes(m);
    }
}
