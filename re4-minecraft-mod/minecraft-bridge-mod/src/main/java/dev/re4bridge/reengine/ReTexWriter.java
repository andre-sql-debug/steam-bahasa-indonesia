package dev.re4bridge.reengine;

import java.io.IOException;
import java.io.OutputStream;
import java.util.Objects;

/*
 * The RE4 tex header and mip layout written here is ported from REE-Lib's TexFile (Modern serializer,
 * LoadDataFromDDS): https://github.com/kagenocookie/REE-Lib  (REE-Lib/OtherFiles/TexFile.cs)
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
 * Writes Resident Evil 4 (2023) {@code .tex.143221013} textures: uncompressed R8G8B8A8 (DXGI 29 sRGB for colour,
 * DXGI 28 linear for data maps), one image, full mip chain made with a 2x2 box filter.
 *
 * <p>Pixels are passed as {@code int} ARGB ({@code 0xAARRGGBB}, as {@code BufferedImage.getRGB}); use
 * {@link #abgrToArgb} for Minecraft {@code NativeImage} pixels (ABGR). Row 0 is the top row.
 */
public final class ReTexWriter {
    public static final int FILE_VERSION = 143221013;
    public static final String EXTENSION = ".tex." + FILE_VERSION;
    public static final int DXGI_R8G8B8A8_UNORM = 28;
    public static final int DXGI_R8G8B8A8_UNORM_SRGB = 29;
    public static final int MAX_SIZE = 16384;

    static final int MAGIC = 0x00584554; // "TEX"
    static final int HEADER_SIZE = 40;
    static final int MIP_HEADER_SIZE = 16;
    /** Row pitch alignment: REE-Lib pads every row to a multiple of 256 bytes ("because REE does that"). */
    static final int PITCH_ALIGN = 256;

    private ReTexWriter() {
    }

    /** What the texture holds; decides the DXGI format and how mip levels are averaged. */
    public enum Kind {
        /**
         * {@code BaseDielectricMap} of the RE4 Env/Character master materials: sRGB colour in RGB, and
         * "dielectric" in alpha (1 = not metal), so alpha is written as 255. Colours of the smaller mips are
         * weighted by the source alpha so fully transparent pixels do not darken cut-out edges.
         */
        BASE_DIELECTRIC(true, true, true),
        /** sRGB colour with real alpha (coverage) kept; colours weighted by alpha in the mips. */
        COLOR_WITH_ALPHA(true, true, false),
        /** Linear data (masks such as ATOS): every channel averaged on its own. */
        LINEAR_DATA(false, false, false);

        final boolean srgb;
        final boolean alphaWeighted;
        final boolean opaqueAlpha;

        Kind(boolean srgb, boolean alphaWeighted, boolean opaqueAlpha) {
            this.srgb = srgb;
            this.alphaWeighted = alphaWeighted;
            this.opaqueAlpha = opaqueAlpha;
        }

        public int dxgiFormat() {
            return srgb ? DXGI_R8G8B8A8_UNORM_SRGB : DXGI_R8G8B8A8_UNORM;
        }
    }

    public static void write(OutputStream out, int[] argb, int width, int height, Kind kind) throws IOException {
        out.write(toBytes(argb, width, height, kind));
    }

    /** Full mip chain down to 1x1. */
    public static byte[] toBytes(int[] argb, int width, int height, Kind kind) {
        return toBytes(argb, width, height, kind, 1);
    }

    /**
     * @param smallestMipWidth stop the mip chain before a level narrower than this (the first level is always
     *                         written). With 64, every level's row is a whole multiple of 256 bytes, so the file is
     *                         the same whichever row-pitch rule the game uses for small mips (REE-Lib pads rows to
     *                         256 bytes, RE-Mesh-Editor to 32 bytes for RGBA8); 1 writes the full chain.
     */
    public static byte[] toBytes(int[] argb, int width, int height, Kind kind, int smallestMipWidth) {
        Objects.requireNonNull(argb, "argb");
        Objects.requireNonNull(kind, "kind");
        if (width < 1 || height < 1 || width > MAX_SIZE || height > MAX_SIZE) {
            throw new IllegalArgumentException("texture size " + width + "x" + height + " outside 1.." + MAX_SIZE);
        }
        if (argb.length != width * height) {
            throw new IllegalArgumentException("expected " + width * height + " pixels, got " + argb.length);
        }
        int[][] chain = buildMipChain(argb, width, height, kind);
        int mips = 1;
        while (mips < chain.length && Math.max(1, width >> mips) >= smallestMipWidth) {
            mips++;
        }

        int dataSize = 0;
        for (int m = 0; m < mips; m++) {
            int mw = Math.max(1, width >> m), mh = Math.max(1, height >> m);
            dataSize += pitch(mw) * mh;
        }
        LeBuffer b = new LeBuffer(HEADER_SIZE + mips * MIP_HEADER_SIZE + dataSize);
        b.i32(MAGIC);
        b.i32(FILE_VERSION);
        b.u16(width);
        b.u16(height);
        b.u16(1);                   // depth
        b.u8(1);                    // image count
        b.u8(mips * MIP_HEADER_SIZE);
        b.i32(kind.dxgiFormat());
        b.i32(-1);                  // swizzle control (none)
        b.i32(0);                   // cubemap marker
        b.i32(0);                   // flags (not streamed)
        b.u8(0);                    // swizzle height/depth
        b.u8(0);                    // swizzle width
        b.u16(0);
        b.u16(0);                   // "seven" (0 in new files from REE-Lib and RE-Mesh-Editor)
        b.u16(0);                   // "one"

        int offset = HEADER_SIZE + mips * MIP_HEADER_SIZE;
        for (int m = 0; m < mips; m++) {
            int mw = Math.max(1, width >> m), mh = Math.max(1, height >> m);
            int pitch = pitch(mw);
            b.i64(offset);
            b.i32(pitch);
            b.i32(pitch * mh);
            offset += pitch * mh;
        }
        for (int m = 0; m < mips; m++) {
            int mw = Math.max(1, width >> m), mh = Math.max(1, height >> m);
            int pad = pitch(mw) - mw * 4;
            int[] px = chain[m];
            byte[] row = new byte[mw * 4];
            for (int y = 0; y < mh; y++) {
                for (int x = 0; x < mw; x++) {
                    int c = px[y * mw + x];
                    row[x * 4] = (byte) (c >>> 16);      // R
                    row[x * 4 + 1] = (byte) (c >>> 8);   // G
                    row[x * 4 + 2] = (byte) c;           // B
                    row[x * 4 + 3] = (byte) (c >>> 24);  // A
                }
                b.bytes(row);
                b.zeros(pad);
            }
        }
        if (b.size() != offset) {
            throw new IllegalStateException("tex size mismatch");
        }
        return b.toByteArray();
    }

    /** Number of levels down to 1x1. */
    public static int mipCount(int width, int height) {
        int levels = 1;
        int size = Math.max(width, height);
        while (size > 1) {
            size >>= 1;
            levels++;
        }
        return levels;
    }

    static int pitch(int mipWidth) {
        int row = mipWidth * 4;
        return (row + PITCH_ALIGN - 1) / PITCH_ALIGN * PITCH_ALIGN;
    }

    /**
     * Level 0 (with the alpha rule of {@code kind} applied) followed by every smaller level, each made from the
     * previous one by a 2x2 box filter (sRGB colours averaged in linear light).
     */
    public static int[][] buildMipChain(int[] argb, int width, int height, Kind kind) {
        int mips = mipCount(width, height);
        int[][] chain = new int[mips][];
        int[] level = argb.clone();
        int w = width, h = height;
        for (int m = 0; m < mips; m++) {
            if (m > 0) {
                int nw = Math.max(1, w >> 1), nh = Math.max(1, h >> 1);
                level = downsample(level, w, h, nw, nh, kind);
                w = nw;
                h = nh;
            }
            chain[m] = level;
        }
        if (kind.opaqueAlpha) {
            for (int[] lv : chain) {
                for (int i = 0; i < lv.length; i++) {
                    lv[i] |= 0xFF000000;
                }
            }
        }
        return chain;
    }

    private static int[] downsample(int[] src, int sw, int sh, int dw, int dh, Kind kind) {
        int[] dst = new int[dw * dh];
        int[] xs = new int[2];
        int[] ys = new int[2];
        for (int y = 0; y < dh; y++) {
            ys[0] = Math.min(sh - 1, y * 2);
            ys[1] = Math.min(sh - 1, y * 2 + 1);
            for (int x = 0; x < dw; x++) {
                xs[0] = Math.min(sw - 1, x * 2);
                xs[1] = Math.min(sw - 1, x * 2 + 1);
                double sa = 0, sr = 0, sg = 0, sb = 0, wsum = 0;
                double pr = 0, pg = 0, pb = 0;
                for (int j = 0; j < 2; j++) {
                    for (int i = 0; i < 2; i++) {
                        int c = src[ys[j] * sw + xs[i]];
                        int a = c >>> 24;
                        double r = channel((c >>> 16) & 0xFF, kind.srgb);
                        double g = channel((c >>> 8) & 0xFF, kind.srgb);
                        double bl = channel(c & 0xFF, kind.srgb);
                        sa += a;
                        pr += r;
                        pg += g;
                        pb += bl;
                        double wgt = kind.alphaWeighted ? a : 1;
                        sr += r * wgt;
                        sg += g * wgt;
                        sb += bl * wgt;
                        wsum += wgt;
                    }
                }
                double r, g, bl;
                if (wsum > 0) {
                    r = sr / wsum;
                    g = sg / wsum;
                    bl = sb / wsum;
                } else {
                    r = pr / 4;
                    g = pg / 4;
                    bl = pb / 4;
                }
                int a = (int) Math.round(sa / 4);
                dst[y * dw + x] = (a << 24) | (encode(r, kind.srgb) << 16) | (encode(g, kind.srgb) << 8)
                        | encode(bl, kind.srgb);
            }
        }
        return dst;
    }

    private static final double[] SRGB_TO_LINEAR = new double[256];

    static {
        for (int i = 0; i < 256; i++) {
            double c = i / 255.0;
            SRGB_TO_LINEAR[i] = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        }
    }

    private static double channel(int v, boolean srgb) {
        return srgb ? SRGB_TO_LINEAR[v] : v / 255.0;
    }

    static int encode(double linear, boolean srgb) {
        double c = linear;
        if (srgb) {
            c = linear <= 0.0031308 ? linear * 12.92 : 1.055 * Math.pow(linear, 1.0 / 2.4) - 0.055;
        }
        long v = Math.round(c * 255.0);
        return (int) Math.max(0, Math.min(255, v));
    }

    /** Nearest-neighbour upscaling (each pixel becomes a factor x factor block): keeps pixel art crisp. */
    public static int[] upscaleNearest(int[] argb, int width, int height, int factor) {
        if (factor < 1) {
            throw new IllegalArgumentException("factor " + factor);
        }
        if (argb.length != width * height) {
            throw new IllegalArgumentException("expected " + width * height + " pixels, got " + argb.length);
        }
        if ((long) width * factor > MAX_SIZE || (long) height * factor > MAX_SIZE) {
            throw new IllegalArgumentException("upscaled size exceeds " + MAX_SIZE);
        }
        int ow = width * factor, oh = height * factor;
        int[] out = new int[ow * oh];
        for (int y = 0; y < oh; y++) {
            int sy = y / factor;
            for (int x = 0; x < ow; x++) {
                out[y * ow + x] = argb[sy * width + x / factor];
            }
        }
        return out;
    }

    /** Largest power-of-two factor (at most {@code maxFactor}) that keeps both sides within {@code maxSize}. */
    public static int upscaleFactor(int width, int height, int maxSize, int maxFactor) {
        int f = 1;
        while (f * 2 <= maxFactor && (long) width * f * 2 <= maxSize && (long) height * f * 2 <= maxSize) {
            f *= 2;
        }
        return f;
    }

    /**
     * Builds an {@code AlphaTranslucentOcclusionSSSMap} (ATOS) image from the alpha of a colour image:
     * R = alpha, G = translucency 0, B = occlusion 1 (none), A = SSS 0. Write it with {@link Kind#LINEAR_DATA}.
     */
    public static int[] alphaToAtos(int[] argb) {
        int[] out = new int[argb.length];
        for (int i = 0; i < argb.length; i++) {
            out[i] = ((argb[i] >>> 24) << 16) | 0x0000FF;
        }
        return out;
    }

    /** True if any pixel is not fully opaque (the mob needs the alpha-tested material). */
    public static boolean hasTransparency(int[] argb) {
        for (int c : argb) {
            if ((c >>> 24) != 0xFF) {
                return true;
            }
        }
        return false;
    }

    /** Minecraft {@code NativeImage} pixels are ABGR; swaps red and blue to ARGB. */
    public static int abgrToArgb(int abgr) {
        return (abgr & 0xFF00FF00) | ((abgr & 0x00FF0000) >>> 16) | ((abgr & 0x000000FF) << 16);
    }
}
