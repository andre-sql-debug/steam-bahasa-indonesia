package dev.re4bridge.reengine;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

/*
 * The RE4 mesh layout written here is ported from REE-Lib's MeshFile (MeshSerializerVersion.RE4 path):
 * https://github.com/kagenocookie/REE-Lib  (REE-Lib/OtherFiles/MeshFile.cs)
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
 * Writes a Resident Evil 4 (2023) {@code .mesh.221108797} file (internal version 220822879) holding one static
 * (non-skinned) mesh: one LOD, one mesh group, one sub-mesh, one material referenced by name. The material name
 * must equal the material name inside the {@code .mdf2} that the game pairs with the mesh.
 *
 * <p>Conventions (RE Engine's, as RE-Mesh-Editor and REE-Lib import them unchanged): right-handed, Y up, metres,
 * counter-clockwise triangles are front faces. UVs use the image convention: (0,0) is the top-left pixel corner,
 * v grows downwards, which is also how Minecraft's texture coordinates run.
 *
 * <p>Vertex layout written (three streams, like the RE4 exporters): Position float3 (12 bytes), packed
 * normal+tangent (8 bytes: 4 signed bytes normal xyz + 0, 4 signed bytes tangent xyz + bitangent sign) and
 * UV0 as two half floats (4 bytes). Indices are 16-bit (32-bit above 65534 vertices).
 */
public final class ReMeshWriter {
    public static final int FILE_VERSION = 221108797;
    public static final int INTERNAL_VERSION = 220822879;
    public static final String EXTENSION = ".mesh." + FILE_VERSION;

    static final int MAGIC = 0x4853454D; // "MESH"
    static final int HEADER_SIZE = 168;

    /**
     * Header content flags. Bit 9 (= stream buffer count 1) is set by every RE4 exporter; bit 7 is set by
     * RE-Mesh-Editor and the Noesis plugin for RE4 and bit 15 by RE-Mesh-Editor and REE-Lib. 0x8280 is what
     * RE-Mesh-Editor writes for a static RE4 mesh, the combination most used in RE4 mods.
     */
    public static final int CONTENT_FLAGS = 0x8280;
    /** "skinWeightCount" byte of the LOD header; 18 for RE2/3 RT, RE4 and DD2 (REE-Lib, RE-Mesh-Editor). */
    static final int SKIN_WEIGHT_COUNT = 18;

    // Vertex element types (REE-Lib VertexBufferType)
    static final int ELEMENT_POSITION = 0;
    static final int ELEMENT_NORMAL_TANGENT = 1;
    static final int ELEMENT_UV0 = 2;

    private ReMeshWriter() {
    }

    /** Optional settings; the defaults are what the Minecraft bridge needs. */
    public static final class Options {
        float lodFactor = 0.0F;
        boolean shadowLod = false;
        float[] tangents;

        /** LOD switch factor of the only LOD. 0 (REE-Lib's default) keeps the single LOD at any distance. */
        public Options lodFactor(float factor) {
            this.lodFactor = factor;
            return this;
        }

        /**
         * Adds a shadow-LOD table whose only entry points at the main LOD (how vanilla meshes share it). Off by
         * default: RE-Mesh-Editor, REE-Lib and the Noesis plugin all write new meshes without it.
         */
        public Options shadowLod(boolean enabled) {
            this.shadowLod = enabled;
            return this;
        }

        /** Own tangents, 4 floats per vertex (xyz + bitangent sign); computed from the UVs when not given. */
        public Options tangents(float[] tangents) {
            this.tangents = tangents;
            return this;
        }
    }

    /** Positions, normals, UVs and triangle indices of one mesh. */
    public record Geometry(float[] positions, float[] normals, float[] uvs, int[] indices) {
    }

    public static void write(OutputStream out, String materialName, float[] positions, float[] normals,
                             float[] uvs, int[] indices) throws IOException {
        out.write(toBytes(materialName, positions, normals, uvs, indices, new Options()));
    }

    public static void write(OutputStream out, String materialName, float[] positions, float[] normals,
                             float[] uvs, int[] indices, Options options) throws IOException {
        out.write(toBytes(materialName, positions, normals, uvs, indices, options));
    }

    public static byte[] toBytes(String materialName, float[] positions, float[] normals, float[] uvs,
                                 int[] indices) {
        return toBytes(materialName, positions, normals, uvs, indices, new Options());
    }

    /**
     * @param positions x,y,z per vertex
     * @param normals   x,y,z per vertex (normalised here)
     * @param uvs       u,v per vertex, image convention (v down)
     * @param indices   triangle list, counter-clockwise = front
     */
    public static byte[] toBytes(String materialName, float[] positions, float[] normals, float[] uvs,
                                 int[] indices, Options options) {
        Objects.requireNonNull(options, "options");
        checkName(materialName);
        Objects.requireNonNull(positions, "positions");
        Objects.requireNonNull(normals, "normals");
        Objects.requireNonNull(uvs, "uvs");
        Objects.requireNonNull(indices, "indices");
        if (positions.length == 0 || positions.length % 3 != 0) {
            throw new IllegalArgumentException("positions must hold x,y,z per vertex, got " + positions.length);
        }
        int n = positions.length / 3;
        if (normals.length != n * 3) {
            throw new IllegalArgumentException("normals: expected " + n * 3 + " floats, got " + normals.length);
        }
        if (uvs.length != n * 2) {
            throw new IllegalArgumentException("uvs: expected " + n * 2 + " floats, got " + uvs.length);
        }
        if (indices.length == 0 || indices.length % 3 != 0) {
            throw new IllegalArgumentException("indices must be a non-empty triangle list, got " + indices.length);
        }
        for (int i : indices) {
            if (i < 0 || i >= n) {
                throw new IllegalArgumentException("index " + i + " out of range for " + n + " vertices");
            }
        }
        checkFinite("positions", positions);
        checkFinite("normals", normals);
        checkFinite("uvs", uvs);
        for (float f : uvs) {
            if (Math.abs(f) > 65504.0F) {
                throw new IllegalArgumentException("UV " + f + " does not fit a half float");
            }
        }

        boolean intFaces = n >= 0xFFFF;
        // A 16-bit index list with an odd index count needs 2 padding bytes, and the exporters disagree on
        // whether the mesh-group count includes that padding. Avoid the question: add one zero-area triangle
        // (the GPU drops it), so the count is always even.
        int[] faces = indices;
        if (!intFaces && (indices.length & 1) != 0) {
            faces = new int[indices.length + 3];
            System.arraycopy(indices, 0, faces, 0, indices.length);
            int last = indices[indices.length - 1];
            faces[indices.length] = last;
            faces[indices.length + 1] = last;
            faces[indices.length + 2] = last;
        }
        int indexCount = faces.length;

        float[] unitNormals = normalizedNormals(normals);
        float[] tangents = options.tangents;
        if (tangents == null) {
            tangents = computeTangents(positions, unitNormals, uvs, indices);
        } else if (tangents.length != n * 4) {
            throw new IllegalArgumentException("tangents: expected " + n * 4 + " floats, got " + tangents.length);
        }

        // Bounds: axis-aligned box of all vertices; sphere around the box centre (REE-Lib RecalculateBounds)
        float minX = Float.POSITIVE_INFINITY, minY = Float.POSITIVE_INFINITY, minZ = Float.POSITIVE_INFINITY;
        float maxX = Float.NEGATIVE_INFINITY, maxY = Float.NEGATIVE_INFINITY, maxZ = Float.NEGATIVE_INFINITY;
        for (int v = 0; v < n; v++) {
            float x = positions[v * 3], y = positions[v * 3 + 1], z = positions[v * 3 + 2];
            minX = Math.min(minX, x); minY = Math.min(minY, y); minZ = Math.min(minZ, z);
            maxX = Math.max(maxX, x); maxY = Math.max(maxY, y); maxZ = Math.max(maxZ, z);
        }
        float cx = (minX + maxX) * 0.5F, cy = (minY + maxY) * 0.5F, cz = (minZ + maxZ) * 0.5F;
        double maxDistSq = 0;
        for (int v = 0; v < n; v++) {
            double dx = positions[v * 3] - cx, dy = positions[v * 3 + 1] - cy, dz = positions[v * 3 + 2] - cz;
            maxDistSq = Math.max(maxDistSq, dx * dx + dy * dy + dz * dz);
        }
        float radius = (float) Math.sqrt(maxDistSq);

        int indexSize = intFaces ? 4 : 2;
        LeBuffer b = new LeBuffer(HEADER_SIZE + 1024 + n * 24 + indexCount * indexSize);

        // ---- File header (written last, see the end) ----
        b.zeros(HEADER_SIZE);

        // ---- Main mesh data (REE-Lib MeshData) ----
        b.align(8);
        int lodsOffset = b.position();
        b.u8(1);                    // lodCount
        b.u8(1);                    // materialCount
        b.u8(1);                    // uvCount (UV0 only)
        b.u8(SKIN_WEIGHT_COUNT);    // skinWeightCount
        b.u16(1);                   // totalMeshCount (sub-meshes in the largest LOD)
        b.u8(intFaces ? 1 : 0);     // 32-bit index buffer
        b.u8(0);
        b.f32(cx); b.f32(cy); b.f32(cz); b.f32(radius);   // bounding sphere
        b.f32(minX); b.f32(minY); b.f32(minZ); b.f32(0);  // AABB min (vec3 + pad)
        b.f32(maxX); b.f32(maxY); b.f32(maxZ); b.f32(0);  // AABB max (vec3 + pad)
        int lodTablePtr = b.position();
        b.i64(0);
        b.align(8);
        int lodTable = b.position();
        b.putI64(lodTablePtr, lodTable);
        b.i64(0);                   // LOD 0 offset, patched below
        b.align(16);

        // ---- LOD 0 (REE-Lib MeshLOD) ----
        int lod0 = b.position();
        b.putI64(lodTable, lod0);
        b.u8(1);                    // mesh group count
        b.u8(0);                    // vertexFormat
        b.u8(0);
        b.u8(0);
        b.f32(options.lodFactor);
        int groupTablePtr = b.position();
        b.i64(0);
        int groupTable = b.position();
        b.putI64(groupTablePtr, groupTable);
        b.i64(0);                   // group 0 offset, patched below
        b.align(16);

        // ---- Mesh group 0 (REE-Lib MeshGroup) with its one sub-mesh ----
        int group0 = b.position();
        b.putI64(groupTable, group0);
        b.u8(0);                    // group id
        b.u8(1);                    // sub-mesh count
        b.zeros(6);
        b.i32(n);                   // vertex count
        b.i32(indexCount);          // index count
        // Sub-mesh (RE4 layout, 24 bytes)
        b.u16(0);                   // material index
        b.u8(0);                    // buffer index (main buffer)
        b.u8(0);
        b.i32(indexCount);          // index count
        b.i32(0);                   // first index
        b.i32(0);                   // first vertex
        b.i32(0);                   // streaming offset
        b.i32(0);                   // streaming offset 2

        // ---- Optional shadow LOD table pointing at LOD 0 (REE-Lib ShadowMesh, reused LOD) ----
        int shadowLodsOffset = 0;
        if (options.shadowLod) {
            b.align(8);
            shadowLodsOffset = b.position();
            b.u8(1);                // lodCount
            b.u8(1);                // materialCount
            b.u8(1);                // uvCount
            b.u8(SKIN_WEIGHT_COUNT);
            b.u16(1);               // totalMeshCount
            b.zeros(2);
            int shadowTablePtr = b.position();
            b.i64(0);
            b.zeros(48);
            int shadowTable = b.position();
            b.putI64(shadowTablePtr, shadowTable);
            b.i64(lod0);            // shares the main LOD 0
            b.align(16);
        }

        // ---- Material name indices into the name table ----
        b.align(16);
        int materialIndicesOffset = b.position();
        b.u16(0);                   // material 0 -> name 0

        // ---- Name table: offsets, then null-terminated ASCII names ----
        b.align(16);
        int nameOffsetsOffset = b.position();
        b.i64(0);
        b.align(16);
        b.putI64(nameOffsetsOffset, b.position());
        b.bytes(materialName.getBytes(StandardCharsets.US_ASCII));
        b.u8(0);

        // ---- Mesh buffer header (REE-Lib MeshBuffer, RE4: 64 bytes), patched after the data is written ----
        b.align(16);
        int meshOffset = b.position();
        b.zeros(64);
        // Streaming info (no streamed buffers): count 0, offset 0
        b.align(16);
        int streamingInfoOffset = b.position();
        b.i32(0);
        b.i32(0);
        b.i64(0);
        // Vertex element headers
        b.align(16);
        int elementHeadersOffset = b.position();
        b.u16(ELEMENT_POSITION);
        b.u16(12);
        b.i32(0);
        b.u16(ELEMENT_NORMAL_TANGENT);
        b.u16(8);
        b.i32(12 * n);
        b.u16(ELEMENT_UV0);
        b.u16(4);
        b.i32(20 * n);
        b.align(16);

        // ---- Vertex buffer: positions, normals+tangents, UV0 ----
        int vertexBufferOffset = b.position();
        for (int v = 0; v < n * 3; v++) {
            b.f32(positions[v]);
        }
        for (int v = 0; v < n; v++) {
            b.u8(quantizeUnit(unitNormals[v * 3]));
            b.u8(quantizeUnit(unitNormals[v * 3 + 1]));
            b.u8(quantizeUnit(unitNormals[v * 3 + 2]));
            b.u8(0);
            b.u8(quantizeUnit(tangents[v * 4]));
            b.u8(quantizeUnit(tangents[v * 4 + 1]));
            b.u8(quantizeUnit(tangents[v * 4 + 2]));
            b.u8(tangents[v * 4 + 3] < 0 ? -128 : 127);   // bitangent sign
        }
        for (int v = 0; v < n * 2; v++) {
            b.u16(Float.floatToFloat16(uvs[v]));
        }
        b.align(16);
        int vertexBufferSize = b.position() - vertexBufferOffset;

        // ---- Index buffer ----
        for (int f : faces) {
            if (intFaces) {
                b.i32(f);
            } else {
                b.u16(f);
            }
        }
        int facesEnd = b.position() - vertexBufferOffset;
        b.align(16);
        int totalBufferSize = b.position() - vertexBufferOffset;
        int fileSize = b.size();

        // Mesh buffer header
        b.seek(meshOffset);
        b.i64(elementHeadersOffset);
        b.i64(vertexBufferOffset);
        b.i64(0);                   // shape-key weight buffer offset
        b.i32(totalBufferSize);
        b.i32(vertexBufferSize);
        b.u16(3);                   // element count
        b.u16(3);                   // total element count
        b.i32(facesEnd);            // shadow face buffer offset (= end of main faces, no shadow faces)
        b.i32(facesEnd);            // occluder face buffer offset (none)
        b.i32(-vertexBufferOffset); // blend shape offset: none (relative offset back to file start)
        b.i32(0);                   // shape-key weight buffer size
        b.i32(0);                   // buffer index
        b.zeros(8);

        // File header (RE4 / SF6-era layout)
        b.seek(0);
        b.i32(MAGIC);
        b.i32(INTERNAL_VERSION);
        b.i32(fileSize);
        b.i32(0);                   // LOD group hash
        b.u16(CONTENT_FLAGS);
        b.u16(0);                   // unknown count (0 for RE4; 84 is DD2's)
        b.u16(1);                   // name count
        b.u16(0);
        b.i64(0);                   // unknown offset
        b.i64(lodsOffset);
        b.i64(shadowLodsOffset);
        b.i64(0);                   // occluder mesh
        b.i64(0);                   // normal recalculation
        b.i64(0);                   // blend shape headers
        b.i64(meshOffset);
        b.i64(0);
        b.i64(0);                   // floats (group pivots)
        b.i64(0);                   // bone bounds
        b.i64(0);                   // bones
        b.i64(materialIndicesOffset);
        b.i64(0);                   // bone name indices
        b.i64(0);                   // blend shape name indices
        b.i64(streamingInfoOffset);
        b.i64(nameOffsetsOffset);
        b.i64(vertexBufferOffset);  // vertices offset
        b.i64(0);                   // SDF texture path
        if (b.position() != HEADER_SIZE) {
            throw new IllegalStateException("mesh header size " + b.position());
        }
        return b.toByteArray();
    }

    /**
     * Per-vertex tangents (x, y, z, bitangent sign) from positions, unit normals and UVs (image convention).
     * The sign follows RE-Mesh-Editor/Blender: bitangent = sign * cross(normal, tangent) points towards
     * decreasing image v (up in the texture), so an unmirrored face gets +1.
     */
    public static float[] computeTangents(float[] positions, float[] unitNormals, float[] uvs, int[] indices) {
        int n = positions.length / 3;
        double[] t = new double[n * 3];
        double[] bt = new double[n * 3];
        for (int i = 0; i + 2 < indices.length; i += 3) {
            int i0 = indices[i], i1 = indices[i + 1], i2 = indices[i + 2];
            double e1x = positions[i1 * 3] - positions[i0 * 3];
            double e1y = positions[i1 * 3 + 1] - positions[i0 * 3 + 1];
            double e1z = positions[i1 * 3 + 2] - positions[i0 * 3 + 2];
            double e2x = positions[i2 * 3] - positions[i0 * 3];
            double e2y = positions[i2 * 3 + 1] - positions[i0 * 3 + 1];
            double e2z = positions[i2 * 3 + 2] - positions[i0 * 3 + 2];
            double du1 = uvs[i1 * 2] - uvs[i0 * 2], dv1 = uvs[i1 * 2 + 1] - uvs[i0 * 2 + 1];
            double du2 = uvs[i2 * 2] - uvs[i0 * 2], dv2 = uvs[i2 * 2 + 1] - uvs[i0 * 2 + 1];
            double det = du1 * dv2 - du2 * dv1;
            if (Math.abs(det) < 1e-20) {
                continue;
            }
            double r = 1.0 / det;
            // dP/du and dP/dv (image v)
            double tx = (e1x * dv2 - e2x * dv1) * r, ty = (e1y * dv2 - e2y * dv1) * r, tz = (e1z * dv2 - e2z * dv1) * r;
            double bx = (e2x * du1 - e1x * du2) * r, by = (e2y * du1 - e1y * du2) * r, bz = (e2z * du1 - e1z * du2) * r;
            for (int k = 0; k < 3; k++) {
                int v = indices[i + k];
                t[v * 3] += tx; t[v * 3 + 1] += ty; t[v * 3 + 2] += tz;
                bt[v * 3] += bx; bt[v * 3 + 1] += by; bt[v * 3 + 2] += bz;
            }
        }
        float[] out = new float[n * 4];
        for (int v = 0; v < n; v++) {
            double nx = unitNormals[v * 3], ny = unitNormals[v * 3 + 1], nz = unitNormals[v * 3 + 2];
            double tx = t[v * 3], ty = t[v * 3 + 1], tz = t[v * 3 + 2];
            double d = nx * tx + ny * ty + nz * tz;
            tx -= nx * d; ty -= ny * d; tz -= nz * d;
            double len = Math.sqrt(tx * tx + ty * ty + tz * tz);
            if (len < 1e-12) {
                // No usable UV gradient: any direction perpendicular to the normal
                double ax = Math.abs(nx) < 0.9 ? 1 : 0, ay = Math.abs(nx) < 0.9 ? 0 : 1;
                tx = ay * nz;           // cross(a, n) with a = (ax, ay, 0)
                ty = -ax * nz;
                tz = ax * ny - ay * nx;
                len = Math.sqrt(tx * tx + ty * ty + tz * tz);
            }
            tx /= len; ty /= len; tz /= len;
            // cross(n, t) compared with -dP/dv (towards the top of the image)
            double cx = ny * tz - nz * ty, cy = nz * tx - nx * tz, cz = nx * ty - ny * tx;
            double s = -(cx * bt[v * 3] + cy * bt[v * 3 + 1] + cz * bt[v * 3 + 2]);
            out[v * 4] = (float) tx;
            out[v * 4 + 1] = (float) ty;
            out[v * 4 + 2] = (float) tz;
            out[v * 4 + 3] = s < 0 ? -1.0F : 1.0F;
        }
        return out;
    }

    /**
     * Appends a back-facing copy of every triangle (same positions and UVs, flipped normals, reversed winding),
     * so the mesh is visible from both sides with a single-sided material.
     */
    public static Geometry withBackFaces(float[] positions, float[] normals, float[] uvs, int[] indices) {
        int n = positions.length / 3;
        float[] p = new float[positions.length * 2];
        float[] no = new float[normals.length * 2];
        float[] uv = new float[uvs.length * 2];
        int[] ix = new int[indices.length * 2];
        System.arraycopy(positions, 0, p, 0, positions.length);
        System.arraycopy(positions, 0, p, positions.length, positions.length);
        System.arraycopy(normals, 0, no, 0, normals.length);
        for (int i = 0; i < normals.length; i++) {
            no[normals.length + i] = -normals[i];
        }
        System.arraycopy(uvs, 0, uv, 0, uvs.length);
        System.arraycopy(uvs, 0, uv, uvs.length, uvs.length);
        System.arraycopy(indices, 0, ix, 0, indices.length);
        for (int i = 0; i + 2 < indices.length; i += 3) {
            ix[indices.length + i] = indices[i] + n;
            ix[indices.length + i + 1] = indices[i + 2] + n;
            ix[indices.length + i + 2] = indices[i + 1] + n;
        }
        return new Geometry(p, no, uv, ix);
    }

    /** REE-Lib SByte4.QuantizeNormalSingle: round((v * 255 - 1) / 2), round-half-even like .NET. */
    static int quantizeUnit(float value) {
        double q = Math.rint((value * 255.0 - 1.0) * 0.5);
        return (int) Math.max(-128, Math.min(127, q));
    }

    private static float[] normalizedNormals(float[] normals) {
        float[] out = new float[normals.length];
        for (int i = 0; i < normals.length; i += 3) {
            double x = normals[i], y = normals[i + 1], z = normals[i + 2];
            double len = Math.sqrt(x * x + y * y + z * z);
            if (len < 1e-12) {
                out[i + 1] = 1.0F;
            } else {
                out[i] = (float) (x / len);
                out[i + 1] = (float) (y / len);
                out[i + 2] = (float) (z / len);
            }
        }
        return out;
    }

    /** Material names: 1..255 printable ASCII characters without spaces (shared with {@link ReMdfWriter}). */
    static void checkName(String name) {
        Objects.requireNonNull(name, "materialName");
        if (name.isEmpty() || name.length() > 255) {
            throw new IllegalArgumentException("material name must be 1..255 characters");
        }
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            if (c < 0x21 || c > 0x7E) {
                throw new IllegalArgumentException("material name must be printable ASCII without spaces: " + name);
            }
        }
    }

    private static void checkFinite(String what, float[] values) {
        for (float f : values) {
            if (!Float.isFinite(f)) {
                throw new IllegalArgumentException(what + " contains a non-finite value");
            }
        }
    }
}
