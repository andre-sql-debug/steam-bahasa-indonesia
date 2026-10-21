package dev.re4bridge;

/**
 * RE4 file contents for Re4Native (model, texture, material). Placeholder until the RE4 format writers are in.
 */
final class Re4NativeFiles {
    static final String MESH_VERSION = "221108797";
    static final String TEX_VERSION = "143221013";
    static final String MDF_VERSION = "32";
    // Part of every file name: a corrected writer makes new names, so RE4 never keeps an old copy cached
    static final int FORMAT_REV = 1;

    private Re4NativeFiles() {
    }

    // Never hand RE4 a file it can't read (it may crash): nothing is written until the writers are in
    static byte[] mesh(String material, float[] positions, float[] normals, float[] uvs) {
        throw new UnsupportedOperationException("RE4 model writer not built yet");
    }

    static byte[] texture(int[] image, int maxSize) {
        throw new UnsupportedOperationException("RE4 texture writer not built yet");
    }

    static byte[] material(String material, String texturePath) {
        throw new UnsupportedOperationException("RE4 material writer not built yet");
    }
}
