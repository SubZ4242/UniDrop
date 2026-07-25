package com.unidrop.receiver;

import android.content.Context;

import java.io.EOFException;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.UUID;
import java.util.zip.GZIPInputStream;
import java.util.zip.InflaterInputStream;

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
                int compressedLength = ((lengthBytes[0] & 0xff) << 24)
                    | ((lengthBytes[1] & 0xff) << 16)
                    | ((lengthBytes[2] & 0xff) << 8)
                    | (lengthBytes[3] & 0xff);
                if (compressedLength == 0) {
                    break;
                }
                if (compressedLength < 0) {
                    throw new IOException("Invalid DVZip chunk length " + compressedLength);
                }
                LimitedInputStream limited = new LimitedInputStream(input, compressedLength);
                try (InflaterInputStream inflater = new InflaterInputStream(limited)) {
                    byte[] buffer = new byte[128 * 1024];
                    int n;
                    while ((n = inflater.read(buffer)) >= 0) {
                        out.write(buffer, 0, n);
                    }
                }
                if (limited.remaining != 0) {
                    throw new EOFException("DVZip chunk ended early");
                }
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
