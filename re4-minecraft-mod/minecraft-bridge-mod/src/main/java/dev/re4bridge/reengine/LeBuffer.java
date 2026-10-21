package dev.re4bridge.reengine;

import java.util.Arrays;

/**
 * Growable little-endian byte buffer with random-access patching, used by the RE Engine file writers.
 * Moving past the end (seek/align/zeros) extends the buffer with zero bytes.
 */
final class LeBuffer {
    private byte[] data;
    private int pos;
    private int size;

    LeBuffer(int initialCapacity) {
        data = new byte[Math.max(64, initialCapacity)];
    }

    int position() {
        return pos;
    }

    int size() {
        return size;
    }

    /** Moves to an absolute position; positions past the end are zero-filled. */
    void seek(int position) {
        if (position < 0) {
            throw new IllegalArgumentException("negative position " + position);
        }
        ensure(position);
        pos = position;
        if (pos > size) {
            size = pos;
        }
    }

    /** Pads with zero bytes until the position is a multiple of {@code alignment}. */
    void align(int alignment) {
        int r = pos % alignment;
        if (r != 0) {
            zeros(alignment - r);
        }
    }

    void zeros(int count) {
        ensure(pos + count);
        Arrays.fill(data, pos, pos + count, (byte) 0);
        advance(count);
    }

    void u8(int v) {
        ensure(pos + 1);
        data[pos] = (byte) v;
        advance(1);
    }

    void u16(int v) {
        ensure(pos + 2);
        data[pos] = (byte) v;
        data[pos + 1] = (byte) (v >>> 8);
        advance(2);
    }

    void i32(int v) {
        ensure(pos + 4);
        data[pos] = (byte) v;
        data[pos + 1] = (byte) (v >>> 8);
        data[pos + 2] = (byte) (v >>> 16);
        data[pos + 3] = (byte) (v >>> 24);
        advance(4);
    }

    void i64(long v) {
        i32((int) v);
        i32((int) (v >>> 32));
    }

    void f32(float v) {
        i32(Float.floatToRawIntBits(v));
    }

    void bytes(byte[] b) {
        bytes(b, 0, b.length);
    }

    void bytes(byte[] b, int off, int len) {
        ensure(pos + len);
        System.arraycopy(b, off, data, pos, len);
        advance(len);
    }

    /** Overwrites a 32-bit value at {@code at} without moving the write position. */
    void putI32(int at, int v) {
        int save = pos;
        seek(at);
        i32(v);
        pos = save;
    }

    /** Overwrites a 64-bit value at {@code at} without moving the write position. */
    void putI64(int at, long v) {
        int save = pos;
        seek(at);
        i64(v);
        pos = save;
    }

    byte[] toByteArray() {
        return Arrays.copyOf(data, size);
    }

    private void advance(int n) {
        pos += n;
        if (pos > size) {
            size = pos;
        }
    }

    private void ensure(int end) {
        if (end < 0) {
            throw new IllegalStateException("RE Engine file larger than 2 GB");
        }
        if (end > data.length) {
            data = Arrays.copyOf(data, Math.max(end, data.length * 2));
        }
    }
}
