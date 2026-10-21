package dev.re4bridge.reengine;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

/**
 * Writes sample RE4 files into the directory given as the first argument, for checking with external readers:
 * <ul>
 *   <li>{@code cube.mesh.221108797}: textured 1 m cube (24 vertices, 12 triangles), material {@code mc_cube}</li>
 *   <li>{@code cube_shadow.mesh.221108797}: the same with the optional shadow-LOD table</li>
 *   <li>{@code cube_backfaces.mesh.221108797}: the cube plus back-facing copies (48 vertices, 24 triangles)</li>
 *   <li>{@code cube.tex.143221013}: 16x16 test image upscaled x8 (128x128, 8 mips), BaseDielectricMap</li>
 *   <li>{@code cube_atos.tex.143221013}: ATOS map made from the test image's alpha (linear)</li>
 *   <li>{@code cube.mdf2.32}, {@code cube_cutout.mdf2.32}, {@code cube_twosided.mdf2.32}: Env_Default materials</li>
 *   <li>{@code selftest_expected.json}: the input data, for comparing what readers decode</li>
 * </ul>
 * Run: {@code java dev.re4bridge.reengine.ReFormatsSelfTest <dir>}. Exits with status 1 if an internal check fails.
 */
public final class ReFormatsSelfTest {
    static final String MATERIAL = "mc_cube";
    static final String TEX_PATH = "minecraft/selftest/cube.tex";
    static final String ATOS_PATH = "minecraft/selftest/cube_atos.tex";
    static final int SRC_SIZE = 16;
    static final int UPSCALE = 8;

    private static int failures = 0;

    private ReFormatsSelfTest() {
    }

    public static void main(String[] args) throws IOException {
        if (args.length != 1) {
            System.err.println("usage: ReFormatsSelfTest <output directory>");
            System.exit(2);
        }
        Path dir = Path.of(args[0]);
        Files.createDirectories(dir);

        // ---- Mesh ----
        float[][] cube = cube();
        float[] positions = cube[0], normals = cube[1], uvs = cube[2];
        int[] indices = cubeIndices();
        write(dir.resolve("cube" + ReMeshWriter.EXTENSION),
                ReMeshWriter.toBytes(MATERIAL, positions, normals, uvs, indices));
        write(dir.resolve("cube_shadow" + ReMeshWriter.EXTENSION),
                ReMeshWriter.toBytes(MATERIAL, positions, normals, uvs, indices,
                        new ReMeshWriter.Options().shadowLod(true)));
        ReMeshWriter.Geometry both = ReMeshWriter.withBackFaces(positions, normals, uvs, indices);
        write(dir.resolve("cube_backfaces" + ReMeshWriter.EXTENSION),
                ReMeshWriter.toBytes(MATERIAL, both.positions(), both.normals(), both.uvs(), both.indices()));

        float[] tangents = ReMeshWriter.computeTangents(positions, normals, uvs, indices);
        boolean tangentsOk = true;
        for (int v = 0; v < 24; v++) {
            float[] right = FACES[v / 4][2];
            tangentsOk &= Math.abs(tangents[v * 4] - right[0]) < 1e-5 && Math.abs(tangents[v * 4 + 1] - right[1]) < 1e-5
                    && Math.abs(tangents[v * 4 + 2] - right[2]) < 1e-5 && tangents[v * 4 + 3] == 1.0F;
        }
        check(tangentsOk, "tangent of every vertex is its face's u direction, bitangent sign +1");
        check(ReMeshWriter.quantizeUnit(1.0F) == 127 && ReMeshWriter.quantizeUnit(-1.0F) == -128
                && ReMeshWriter.quantizeUnit(0.0F) == 0, "normal quantisation of 1, -1, 0");

        // ---- Texture ----
        int[] src = testImage();
        int[] big = ReTexWriter.upscaleNearest(src, SRC_SIZE, SRC_SIZE, UPSCALE);
        int size = SRC_SIZE * UPSCALE;
        write(dir.resolve("cube" + ReTexWriter.EXTENSION),
                ReTexWriter.toBytes(big, size, size, ReTexWriter.Kind.BASE_DIELECTRIC));
        write(dir.resolve("cube_atos" + ReTexWriter.EXTENSION),
                ReTexWriter.toBytes(ReTexWriter.alphaToAtos(big), size, size, ReTexWriter.Kind.LINEAR_DATA));

        int[][] chain = ReTexWriter.buildMipChain(big, size, size, ReTexWriter.Kind.BASE_DIELECTRIC);
        check(chain.length == 8, "128x128 has 8 mip levels");
        boolean same = true;
        for (int i = 0; i < src.length; i++) {
            same &= chain[3][i] == (src[i] | 0xFF000000);
        }
        check(same, "mip 3 of the x8 upscale equals the 16x16 source (alpha forced to 255)");
        boolean roundTrip = true;
        for (int c = 0; c < 256; c++) {
            int p = 0xFF000000 | c << 16 | c << 8 | c;
            int[] mip = ReTexWriter.buildMipChain(new int[]{p, p, p, p}, 2, 2, ReTexWriter.Kind.COLOR_WITH_ALPHA)[1];
            roundTrip &= mip[0] == p;
        }
        check(roundTrip, "sRGB -> linear -> sRGB keeps all 256 values");
        check(ReTexWriter.abgrToArgb(0x80112233) == 0x80332211, "ABGR -> ARGB swap");

        // ---- Materials ----
        write(dir.resolve("cube" + ReMdfWriter.EXTENSION),
                ReMdfWriter.toBytes(new ReMdfWriter.Material(MATERIAL, TEX_PATH)));
        write(dir.resolve("cube_cutout" + ReMdfWriter.EXTENSION),
                ReMdfWriter.toBytes(new ReMdfWriter.Material(MATERIAL, TEX_PATH).alphaTest(ATOS_PATH, 0.5F)));
        write(dir.resolve("cube_twosided" + ReMdfWriter.EXTENSION),
                ReMdfWriter.toBytes(new ReMdfWriter.Material(MATERIAL, TEX_PATH).doubleSided(true)));

        writeExpected(dir.resolve("selftest_expected.json"), positions, normals, uvs, indices, tangents, src);
        writeEdgeCases(dir.resolve("edge"));

        if (failures > 0) {
            System.out.println(failures + " check(s) FAILED");
            System.exit(1);
        }
        System.out.println("all internal checks passed");
    }

    /** Face: normal, up, right (= u direction); right = cross(up, normal) so the quads are counter-clockwise. */
    static final float[][][] FACES = {
            {{1, 0, 0}, {0, 1, 0}, {0, 0, -1}},
            {{-1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
            {{0, 1, 0}, {0, 0, -1}, {1, 0, 0}},
            {{0, -1, 0}, {0, 0, 1}, {1, 0, 0}},
            {{0, 0, 1}, {0, 1, 0}, {1, 0, 0}},
            {{0, 0, -1}, {0, 1, 0}, {-1, 0, 0}},
    };

    /** 1 m cube standing on the origin (centre 0, 0.5, 0); face i maps to 4x4 texel cell (i % 4, i / 4). */
    static float[][] cube() {
        float[] p = new float[24 * 3], n = new float[24 * 3], uv = new float[24 * 2];
        float[][] corners = {{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};   // (right, up) signs
        for (int f = 0; f < 6; f++) {
            float[] nor = FACES[f][0], up = FACES[f][1], right = FACES[f][2];
            float u0 = (f % 4) * 0.25F, v0 = (f / 4) * 0.25F;
            for (int c = 0; c < 4; c++) {
                int v = f * 4 + c;
                for (int k = 0; k < 3; k++) {
                    p[v * 3 + k] = 0.5F * (nor[k] + corners[c][0] * right[k] + corners[c][1] * up[k]) + (k == 1 ? 0.5F : 0);
                    n[v * 3 + k] = nor[k];
                }
                uv[v * 2] = u0 + (corners[c][0] > 0 ? 0.25F : 0);
                uv[v * 2 + 1] = v0 + (corners[c][1] > 0 ? 0 : 0.25F);
            }
        }
        return new float[][]{p, n, uv};
    }

    static int[] cubeIndices() {
        int[] ix = new int[36];
        for (int f = 0; f < 6; f++) {
            int b = f * 4;
            int[] t = {b, b + 1, b + 2, b, b + 2, b + 3};
            System.arraycopy(t, 0, ix, f * 6, 6);
        }
        return ix;
    }

    /** 16x16 ARGB: red = x ramp, green = y ramp, blue = 4x4 checker; top-right 4x4 block transparent. */
    static int[] testImage() {
        int[] px = new int[SRC_SIZE * SRC_SIZE];
        for (int y = 0; y < SRC_SIZE; y++) {
            for (int x = 0; x < SRC_SIZE; x++) {
                int a = (x >= 12 && y < 4) ? 0 : 255;
                int r = x * 17, g = y * 17, b = ((x / 4 + y / 4) % 2) * 255;
                px[y * SRC_SIZE + x] = a << 24 | r << 16 | g << 8 | b;
            }
        }
        return px;
    }

    /**
     * Edge cases: one triangle (odd index count), 70002 vertices (32-bit indices), a non-square 64x32 texture
     * (full chain), a 512x256 texture cut at 64-pixel-wide mips, and a 1x1 texture.
     */
    private static void writeEdgeCases(Path dir) throws IOException {
        Files.createDirectories(dir);
        write(dir.resolve("odd" + ReMeshWriter.EXTENSION), ReMeshWriter.toBytes("mc_odd",
                new float[]{0, 0, 0, 1, 0, 0, 0, 1, 0}, new float[]{0, 0, 1, 0, 0, 1, 0, 0, 1},
                new float[]{0, 1, 1, 1, 0, 0}, new int[]{0, 1, 2}));

        int tris = 23334;
        float[] p = new float[tris * 9], n = new float[tris * 9], uv = new float[tris * 6];
        int[] ix = new int[tris * 3];
        for (int t = 0; t < tris; t++) {
            float x = (t % 200) * 0.01F, z = (t / 200) * 0.01F;
            float[] tri = {x, 0, z, x + 0.01F, 0, z, x, 0, z - 0.01F};
            System.arraycopy(tri, 0, p, t * 9, 9);
            for (int k = 0; k < 3; k++) {
                n[t * 9 + k * 3 + 1] = 1;
                uv[t * 6 + k * 2] = (t % 200) / 200.0F + (k == 1 ? 0.005F : 0);
                uv[t * 6 + k * 2 + 1] = (t / 200) / 117.0F + (k == 2 ? 0.005F : 0);
                ix[t * 3 + k] = t * 3 + k;
            }
        }
        write(dir.resolve("big" + ReMeshWriter.EXTENSION), ReMeshWriter.toBytes("mc_big", p, n, uv, ix));

        int[] rect = new int[64 * 32];
        for (int i = 0; i < rect.length; i++) {
            rect[i] = 0xFF000000 | (i % 64) * 4 << 16 | (i / 64) * 8 << 8 | ((i * 37) & 0xFF);
        }
        write(dir.resolve("rect" + ReTexWriter.EXTENSION), ReTexWriter.toBytes(rect, 64, 32, ReTexWriter.Kind.BASE_DIELECTRIC));
        write(dir.resolve("rect64" + ReTexWriter.EXTENSION), ReTexWriter.toBytes(
                ReTexWriter.upscaleNearest(rect, 64, 32, 8), 512, 256, ReTexWriter.Kind.BASE_DIELECTRIC, 64));
        write(dir.resolve("one" + ReTexWriter.EXTENSION),
                ReTexWriter.toBytes(new int[]{0x80FF8040}, 1, 1, ReTexWriter.Kind.COLOR_WITH_ALPHA));
        check(ReTexWriter.upscaleFactor(64, 32, 512, 8) == 8 && ReTexWriter.upscaleFactor(128, 128, 512, 8) == 4,
                "upscale factor choice");
    }

    private static void write(Path file, byte[] data) throws IOException {
        Files.write(file, data);
        System.out.println(String.format(Locale.ROOT, "wrote %-34s %8d bytes", file.getFileName(), data.length));
    }

    private static void check(boolean ok, String what) {
        if (!ok) {
            failures++;
        }
        System.out.println((ok ? "ok    " : "FAIL  ") + what);
    }

    private static void writeExpected(Path file, float[] positions, float[] normals, float[] uvs, int[] indices,
                                      float[] tangents, int[] image) throws IOException {
        StringBuilder sb = new StringBuilder("{\n");
        sb.append("  \"material\": \"").append(MATERIAL).append("\",\n");
        sb.append("  \"texturePath\": \"").append(TEX_PATH).append("\",\n");
        sb.append("  \"atosPath\": \"").append(ATOS_PATH).append("\",\n");
        sb.append("  \"masterMaterial\": \"").append(ReMdfWriter.MASTER_MATERIAL).append("\",\n");
        sb.append("  \"imageSize\": ").append(SRC_SIZE).append(",\n");
        sb.append("  \"upscale\": ").append(UPSCALE).append(",\n");
        sb.append("  \"positions\": ").append(json(positions)).append(",\n");
        sb.append("  \"normals\": ").append(json(normals)).append(",\n");
        sb.append("  \"uvs\": ").append(json(uvs)).append(",\n");
        sb.append("  \"tangents\": ").append(json(tangents)).append(",\n");
        sb.append("  \"indices\": [");
        for (int i = 0; i < indices.length; i++) {
            sb.append(i == 0 ? "" : ",").append(indices[i]);
        }
        sb.append("],\n  \"imageArgb\": [");
        for (int i = 0; i < image.length; i++) {
            sb.append(i == 0 ? "" : ",").append(image[i] & 0xFFFFFFFFL);
        }
        sb.append("]\n}\n");
        Files.writeString(file, sb.toString(), StandardCharsets.UTF_8);
    }

    private static String json(float[] values) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < values.length; i++) {
            sb.append(i == 0 ? "" : ",").append(Float.toString(values[i]));
        }
        return sb.append("]").toString();
    }
}
