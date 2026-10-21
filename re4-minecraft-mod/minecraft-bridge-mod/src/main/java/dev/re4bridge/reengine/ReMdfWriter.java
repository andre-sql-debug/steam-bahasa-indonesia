package dev.re4bridge.reengine;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/*
 * The RE4 mdf2 layout written here is ported from REE-Lib's MdfFile (file version 32):
 * https://github.com/kagenocookie/REE-Lib  (REE-Lib/OtherFiles/MdfFile.cs, Common/MurMur3HashUtils.cs)
 *
 * MIT License
 *
 * Copyright (c) 2025 shadowcookie
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

/**
 * Writes Resident Evil 4 (2023) {@code .mdf2.32} material files using the stage master material
 * {@code _Chainsaw/MasterMaterial/Master/Env_Default.mmtr}. The parameter list (names, order, defaults,
 * padding), flags and default texture bindings are the values of a vanilla Env_Default material (as recorded
 * in RE-Mesh-Editor's RE4 "Stage" preset); the property block is kept byte-for-byte in that order because the
 * game maps it onto the master material's constants.
 *
 * <p>Texture paths are relative to {@code natives/STM/} and end in {@code .tex} without the version number,
 * e.g. {@code minecraft/zombie/zombie.tex} for {@code natives/STM/minecraft/zombie/zombie.tex.143221013}.
 */
public final class ReMdfWriter {
    public static final int FILE_VERSION = 32;
    public static final String EXTENSION = ".mdf2." + FILE_VERSION;
    public static final String MASTER_MATERIAL = "_Chainsaw/MasterMaterial/Master/Env_Default.mmtr";

    static final int MAGIC = 0x0046444D; // "MDF"
    static final int MATERIAL_HEADER_SIZE = 100;
    static final int TEXTURE_HEADER_SIZE = 32;
    static final int PARAM_HEADER_SIZE = 24;

    // Material flag bits (REE-Lib MaterialFlags / RE-Mesh-Editor MDFFlags)
    /** Disables back-face culling. In-game testing (REE Content Editor): this or ForcedTwoSideEnable work. */
    public static final int FLAG_BASE_TWO_SIDE_ENABLE = 1;
    public static final int FLAG_BASE_ALPHA_TEST_ENABLE = 1 << 1;
    public static final int FLAG_SHADOW_CAST_DISABLE = 1 << 2;
    public static final int FLAG_VERTEX_SHADER_USED = 1 << 3;
    public static final int FLAG_ALPHA_MASK_USED = 1 << 7;
    public static final int FLAG_FORCED_TWO_SIDE_ENABLE = 1 << 8;
    public static final int FLAG_SSS_PROFILE_USED = 1 << 27;

    /** Env_Default flags: VertexShaderUsed | AlphaMaskUsed | SSSProfileUsed (0x08000088). */
    public static final int ENV_DEFAULT_FLAGS = FLAG_VERTEX_SHADER_USED | FLAG_ALPHA_MASK_USED | FLAG_SSS_PROFILE_USED;
    /** Env_Default second flag word: AlphaUsed. */
    public static final int ENV_DEFAULT_FLAGS_B = 2;

    public static final String SLOT_BASE_DIELECTRIC = "BaseDielectricMap";
    public static final String SLOT_NORMAL_ROUGHNESS_CAVITY = "NormalRoughnessCavityMap";
    public static final String SLOT_ATOS = "AlphaTranslucentOcclusionSSSMap";
    public static final String SLOT_OCCLUSION = "OcclusionMap";
    public static final String SLOT_RAIN_STREAK_MASK = "RainStreakMaskMap";
    public static final String SLOT_RAIN_DROPS_MASK = "RainDropsMaskMap";

    /** Env_Default texture slots with the vanilla default textures, in file order. */
    private static final String[][] ENV_DEFAULT_TEXTURES = {
            {SLOT_BASE_DIELECTRIC, "_Chainsaw/MasterMaterial/Textures/NullWhiteBlack.tex"},
            {SLOT_NORMAL_ROUGHNESS_CAVITY, "systems/rendering/NullNormalRoughnessOcclusion.tex"},
            {SLOT_ATOS, "systems/rendering/NullATOS.tex"},
            {SLOT_OCCLUSION, "systems/rendering/NullWhite.tex"},
            {SLOT_RAIN_STREAK_MASK, "_Chainsaw/MasterMaterial/Textures/RainMask2_NRRC.tex"},
            {SLOT_RAIN_DROPS_MASK, "_Chainsaw/MasterMaterial/Textures/RainMask1_NRRC.tex"},
    };

    /** Env_Default parameters in file order: name, default values (1 or 4 floats). */
    private static final Object[][] ENV_DEFAULT_PARAMS = {
            {"BaseColor", new float[]{1.0F, 1.0F, 1.0F, 1.0F}},
            {"BasicMap_Tiling_Offset", new float[]{1.0F, 1.0F, 0.0F, 0.0F}},
            {"BasicMap_UseSecondaryUV", new float[]{0.0F}},
            {"OcclusionMap_UseSecondaryUV", new float[]{0.0F}},
            {"Roughness", new float[]{1.0F}},
            {"BasicMap_Tiling", new float[]{1.0F}},
            {"Use_AdvancedUVSetting", new float[]{0.0F}},
            {"Use_ATOSMap", new float[]{0.0F}},
            {"Translucency", new float[]{0.0F}},
            {"AlphaTestRef", new float[]{0.5F}},
            {"DissolveRate", new float[]{0.0F}},
            {"SSS_Channel", new float[]{0.0F}},
            {"Debug_Rain", new float[]{0.0F}},
            {"Use_OCCGreenChannel_For_RainMask", new float[]{0.0F}},
            {"LocalUseRain", new float[]{1.0F}},
            {"Rain_Tiling", new float[]{2.0F}},
            {"Wetness", new float[]{1.0F}},
            {"RainStreak_Intensity", new float[]{1.0F}},
            {"RainDrops_Intensity", new float[]{1.0F}},
            {"RainStreak_Speed", new float[]{0.8F}},
            {"RainDrops_Speed", new float[]{0.55F}},
    };

    private ReMdfWriter() {
    }

    /** One Env_Default material. */
    public static final class Material {
        final String name;
        final Map<String, String> textures = new LinkedHashMap<>();
        final Map<String, float[]> params = new LinkedHashMap<>();
        int flags = ENV_DEFAULT_FLAGS;
        int flagsB = ENV_DEFAULT_FLAGS_B;

        /**
         * @param name               material name; must equal the material name stored in the .mesh
         * @param baseDielectricPath colour texture, e.g. {@code minecraft/zombie/zombie.tex}
         */
        public Material(String name, String baseDielectricPath) {
            ReMeshWriter.checkName(name);
            this.name = name;
            for (String[] t : ENV_DEFAULT_TEXTURES) {
                textures.put(t[0], t[1]);
            }
            for (Object[] p : ENV_DEFAULT_PARAMS) {
                params.put((String) p[0], ((float[]) p[1]).clone());
            }
            texture(SLOT_BASE_DIELECTRIC, baseDielectricPath);
        }

        /** Replaces the texture of an existing Env_Default slot. */
        public Material texture(String slot, String path) {
            if (!textures.containsKey(slot)) {
                throw new IllegalArgumentException("Env_Default has no texture slot " + slot);
            }
            checkText("texture path", path);
            textures.put(slot, path);
            return this;
        }

        /** Sets an existing Env_Default parameter (1 or 4 values, as the default). */
        public Material param(String name, float... values) {
            float[] old = params.get(name);
            if (old == null) {
                throw new IllegalArgumentException("Env_Default has no parameter " + name);
            }
            if (values.length != old.length) {
                throw new IllegalArgumentException(name + " takes " + old.length + " values");
            }
            params.put(name, values.clone());
            return this;
        }

        /**
         * Two-sided rendering through the {@code BaseTwoSideEnable} flag (bit 0 of the material flags).
         * Do not combine with meshes that already contain back-facing copies of their triangles: the two
         * coplanar surfaces would fight in the depth buffer if the shader does not flip back-face normals.
         */
        public Material doubleSided(boolean enabled) {
            flags = enabled ? flags | FLAG_BASE_TWO_SIDE_ENABLE : flags & ~FLAG_BASE_TWO_SIDE_ENABLE;
            return this;
        }

        /**
         * Alpha-tested (cut-out) rendering: sets {@code BaseAlphaTestEnable}, turns on {@code Use_ATOSMap} and
         * binds an ATOS texture whose red channel is the alpha ({@link ReTexWriter#alphaToAtos}); pixels with
         * alpha below {@code alphaTestRef} are discarded. Env_Default's BaseDielectricMap alpha is not opacity
         * (it is the dielectric/metal mask), hence the separate texture.
         */
        public Material alphaTest(String atosPath, float alphaTestRef) {
            texture(SLOT_ATOS, atosPath);
            param("Use_ATOSMap", 1.0F);
            param("AlphaTestRef", alphaTestRef);
            flags |= FLAG_BASE_ALPHA_TEST_ENABLE;
            return this;
        }

        /** Rain wetness/streak effects of the stage material (on in the vanilla defaults). */
        public Material rain(boolean enabled) {
            return param("LocalUseRain", enabled ? 1.0F : 0.0F);
        }

        /** Raw material flag words, for experiments. */
        public Material flags(int flags, int flagsB) {
            this.flags = flags;
            this.flagsB = flagsB;
            return this;
        }

        public String name() {
            return name;
        }
    }

    public static void write(OutputStream out, String materialName, String baseDielectricPath) throws IOException {
        out.write(toBytes(new Material(materialName, baseDielectricPath)));
    }

    public static void write(OutputStream out, Material... materials) throws IOException {
        out.write(toBytes(materials));
    }

    public static byte[] toBytes(Material... materials) {
        Objects.requireNonNull(materials, "materials");
        if (materials.length == 0 || materials.length > 0x7FFF) {
            throw new IllegalArgumentException("1..32767 materials");
        }
        LeBuffer b = new LeBuffer(4096 * materials.length);
        StringTable strings = new StringTable();

        b.i32(MAGIC);
        b.u16(1);                               // version
        b.u16(materials.length);
        b.i64(0);

        // Strings are stored in first-use order like REE-Lib and RE-Mesh-Editor: material name, master
        // material path, texture slot names and paths, then parameter names
        int[] headerAt = new int[materials.length];
        for (int m = 0; m < materials.length; m++) {
            headerAt[m] = b.position();
            strings.add(materials[m].name, headerAt[m]);
            strings.add(MASTER_MATERIAL, headerAt[m] + 84);
            b.zeros(MATERIAL_HEADER_SIZE);
        }
        int[] texHeadersAt = new int[materials.length];
        for (int m = 0; m < materials.length; m++) {
            texHeadersAt[m] = b.position();
            for (Map.Entry<String, String> t : materials[m].textures.entrySet()) {
                strings.add(t.getKey(), b.position());
                b.i64(0);
                b.i32(hashUtf16(t.getKey()));
                b.i32(hashAscii(t.getKey()));
                strings.add(t.getValue(), b.position());
                b.i64(0);
                b.zeros(8);
            }
        }
        int[] paramHeadersAt = new int[materials.length];
        for (int m = 0; m < materials.length; m++) {
            paramHeadersAt[m] = b.position();
            for (Map.Entry<String, float[]> p : materials[m].params.entrySet()) {
                strings.add(p.getKey(), b.position());
                b.i64(0);
                b.i32(hashUtf16(p.getKey()));
                b.i32(hashAscii(p.getKey()));
                b.i32(0);                       // offset in the parameter block, patched below
                b.u16(p.getValue().length);     // component count
                b.u16(0);
            }
        }
        b.align(8);
        int gpuBuffersAt = b.position();        // no GPU buffers
        strings.write(b);

        int[] paramsAt = new int[materials.length];
        int[] paramsSize = new int[materials.length];
        for (int m = 0; m < materials.length; m++) {
            paramsAt[m] = b.position();
            int i = 0;
            for (float[] values : materials[m].params.values()) {
                b.putI32(paramHeadersAt[m] + i * PARAM_HEADER_SIZE + 16, b.position() - paramsAt[m]);
                for (float v : values) {
                    b.f32(v);
                }
                i++;
            }
            int used = b.position() - paramsAt[m];
            paramsSize[m] = (used + 15) & ~15;
            b.zeros(paramsSize[m] - used);
        }

        for (int m = 0; m < materials.length; m++) {
            Material mat = materials[m];
            b.seek(headerAt[m]);
            b.i64(0);                           // name offset (string table)
            b.i32(hashUtf16(mat.name));
            b.i32(paramsSize[m]);
            b.i32(mat.params.size());
            b.i32(mat.textures.size());
            b.i32(0);                           // GPU buffer name count
            b.i32(0);                           // GPU buffer path count
            b.i32(0);                           // bake texture array size
            b.i32(0);                           // shader type: Standard
            b.i32(mat.flags);
            b.i32(mat.flagsB);
            b.i32(0);                           // shader LOD count
            b.i64(paramHeadersAt[m]);
            b.i64(texHeadersAt[m]);
            b.i64(gpuBuffersAt);
            b.i64(paramsAt[m]);
            b.i64(0);                           // master material path offset (string table)
            b.i64(0);                           // mmtr ID lists: none
        }
        strings.patch(b);
        return b.toByteArray();
    }

    /** UTF-16 strings written once each; every place that refers to a string gets its offset. */
    private static final class StringTable {
        private final Map<String, List<Integer>> refs = new LinkedHashMap<>();
        private final Map<String, Integer> offsets = new LinkedHashMap<>();

        void add(String s, int refAt) {
            refs.computeIfAbsent(s, k -> new ArrayList<>()).add(refAt);
        }

        void write(LeBuffer b) {
            for (String s : refs.keySet()) {
                offsets.put(s, b.position());
                b.bytes(s.getBytes(StandardCharsets.UTF_16LE));
                b.u16(0);
            }
        }

        void patch(LeBuffer b) {
            for (Map.Entry<String, List<Integer>> e : refs.entrySet()) {
                int at = offsets.get(e.getKey());
                for (int ref : e.getValue()) {
                    b.putI64(ref, at);
                }
            }
        }
    }

    /** RE Engine string hash: MurmurHash3 x86 32-bit, seed 0xFFFFFFFF, over UTF-16LE. */
    public static int hashUtf16(String s) {
        return murmur3(s.getBytes(StandardCharsets.UTF_16LE));
    }

    /** The same hash over the ASCII bytes. */
    public static int hashAscii(String s) {
        return murmur3(s.getBytes(StandardCharsets.US_ASCII));
    }

    static int murmur3(byte[] data) {
        final int c1 = 0xcc9e2d51;
        final int c2 = 0x1b873593;
        int h = 0xFFFFFFFF;
        int blocks = data.length / 4;
        for (int i = 0; i < blocks; i++) {
            int o = i * 4;
            int k = (data[o] & 0xFF) | (data[o + 1] & 0xFF) << 8 | (data[o + 2] & 0xFF) << 16 | (data[o + 3] & 0xFF) << 24;
            k *= c1;
            k = Integer.rotateLeft(k, 15);
            k *= c2;
            h ^= k;
            h = Integer.rotateLeft(h, 13);
            h = h * 5 + 0xe6546b64;
        }
        int tail = blocks * 4;
        int rem = data.length & 3;
        if (rem > 0) {
            int k = 0;
            if (rem == 3) {
                k ^= (data[tail + 2] & 0xFF) << 16;
            }
            if (rem >= 2) {
                k ^= (data[tail + 1] & 0xFF) << 8;
            }
            k ^= data[tail] & 0xFF;
            k *= c1;
            k = Integer.rotateLeft(k, 15);
            k *= c2;
            h ^= k;
        }
        h ^= data.length;
        h ^= h >>> 16;
        h *= 0x85ebca6b;
        h ^= h >>> 13;
        h *= 0xc2b2ae35;
        h ^= h >>> 16;
        return h;
    }

    private static void checkText(String what, String s) {
        Objects.requireNonNull(s, what);
        if (s.isEmpty()) {
            throw new IllegalArgumentException(what + " is empty");
        }
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x20 || c > 0x7E || c == '\\') {
                throw new IllegalArgumentException(what + " must be printable ASCII with '/' separators: " + s);
            }
        }
    }
}
