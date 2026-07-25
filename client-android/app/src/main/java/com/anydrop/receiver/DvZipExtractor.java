package com.unidrop.receiver;

import android.content.Context;

import java.io.EOFException;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.UUID;
import java.util.zip.GZIPInputStream;
import java.util.zip.Inflater;
import java.util.zip.InflaterInputStream;
import java.util.zip.ZipException;

public final class DvZipExtractor {
    private DvZipExtractor() {
    }

    public static File toCpioFile(Context context, File archive) throws IOException {
        if (ArchiveExtractor.looksLikeCpio(archive)) {
            return archive;
        }
        if (ArchiveExtractor.looksLikeGzip(archive)) {
            return gunzip(context, archive);
        }
        File output = new File(context.getCacheDir(), "unidrop-dvzip-" + UUID.randomUUID() + ".cpio");
        try (FileInputStream input = new FileInputStream(archive);
             FileOutputStream out = new FileOutputStream(output)) {
            byte[] lengthBytes = new byte[4];
            while (true) {
                int read = readFullyOrEof(input, lengthBytes);
                if (read == 0) {
                    break;
                }
                if (read != 4) {
                    throw new EOFException("Incomplete DVZip chunk length");
                }
                int compressedLength = parseChunkLength(lengthBytes);
                if (compressedLength == 0) {
                    break;
                }
                if (compressedLength < 0) {
                    throw new IOException("Invalid DVZip chunk length " + compressedLength);
                }
                byte[] compressed = new byte[compressedLength];
                readFully(input, compressed);
                inflateChunk(compressed, out);
            }
        }
        return output;
    }

    private static File gunzip(Context context, File input) throws IOException {
        File output = new File(context.getCacheDir(), "unidrop-dvzip-gzip-" + UUID.randomUUID() + ".cpio");
        try (GZIPInputStream gzip = new GZIPInputStream(new FileInputStream(input));
             FileOutputStream out = new FileOutputStream(output)) {
            byte[] buffer = new byte[128 * 1024];
            int read;
            while ((read = gzip.read(buffer)) >= 0) {
                out.write(buffer, 0, read);
            }
        }
        return output;
    }

    private static int readFullyOrEof(FileInputStream input, byte[] buffer) throws IOException {
        int offset = 0;
        while (offset < buffer.length) {
            int read = input.read(buffer, offset, buffer.length - offset);
            if (read < 0) {
                return offset;
            }
            offset += read;
        }
        return offset;
    }

    private static void readFully(FileInputStream input, byte[] buffer) throws IOException {
        int offset = 0;
        while (offset < buffer.length) {
            int read = input.read(buffer, offset, buffer.length - offset);
            if (read < 0) {
                throw new EOFException("DVZip chunk ended early");
            }
            offset += read;
        }
    }

    private static void inflateChunk(byte[] compressed, FileOutputStream out) throws IOException {
        try {
            inflateChunk(compressed, out, false);
        } catch (ZipException zlibFailure) {
            inflateChunk(compressed, out, true);
        }
    }

    private static void inflateChunk(byte[] compressed, FileOutputStream out, boolean rawDeflate) throws IOException {
        Inflater inflater = new Inflater(rawDeflate);
        try (InflaterInputStream stream = new InflaterInputStream(new ByteArrayInputStream(compressed), inflater)) {
            byte[] buffer = new byte[128 * 1024];
            int read;
            while ((read = stream.read(buffer)) >= 0) {
                out.write(buffer, 0, read);
            }
        } finally {
            inflater.end();
        }
    }

    private static int parseChunkLength(byte[] lengthBytes) throws IOException {
        int bigEndian = ((lengthBytes[0] & 0xff) << 24)
            | ((lengthBytes[1] & 0xff) << 16)
            | ((lengthBytes[2] & 0xff) << 8)
            | (lengthBytes[3] & 0xff);
        if (bigEndian >= 0) {
            return bigEndian;
        }
        int flaggedBigEndian = bigEndian & 0x7fffffff;
        if (flaggedBigEndian > 0 && flaggedBigEndian <= 256 * 1024 * 1024) {
            return flaggedBigEndian;
        }
        int littleEndian = (lengthBytes[0] & 0xff)
            | ((lengthBytes[1] & 0xff) << 8)
            | ((lengthBytes[2] & 0xff) << 16)
            | ((lengthBytes[3] & 0xff) << 24);
        if (littleEndian >= 0 && littleEndian <= 256 * 1024 * 1024) {
            return littleEndian;
        }
        throw new IOException("Invalid DVZip chunk length " + bigEndian);
    }

    private static final class LimitedInputStream extends java.io.InputStream {
        private final FileInputStream input;
        private int remaining;

        LimitedInputStream(FileInputStream input, int remaining) {
            this.input = input;
            this.remaining = remaining;
        }

        @Override
        public int read() throws IOException {
            if (remaining <= 0) {
                return -1;
            }
            int value = input.read();
            if (value >= 0) {
                remaining--;
            }
            return value;
        }

        @Override
        public int read(byte[] buffer, int offset, int length) throws IOException {
            if (remaining <= 0) {
                return -1;
            }
            int read = input.read(buffer, offset, Math.min(length, remaining));
            if (read > 0) {
                remaining -= read;
            }
            return read;
        }
    }
}
