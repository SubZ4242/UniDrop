package com.unidrop.receiver;

import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.List;
import java.util.UUID;
import java.util.zip.GZIPInputStream;

public final class ArchiveExtractor {
    private ArchiveExtractor() {
    }

    public static List<String> extract(Context context, File archive, String contentType) throws IOException {
        File cpio = null;
        try {
            if ("application/x-dvzip".equals(contentType)) {
                cpio = DvZipExtractor.toCpioFile(context, archive);
            } else if (looksLikeGzip(archive)) {
                cpio = gunzip(context, archive);
            } else {
                cpio = archive;
            }
            return CpioExtractor.extract(context, cpio);
        } finally {
            if (cpio != null && !cpio.equals(archive) && cpio.exists()) {
                //noinspection ResultOfMethodCallIgnored
                cpio.delete();
            }
        }
    }

    static boolean looksLikeCpio(File file) throws IOException {
        byte[] header = readHeader(file, 6);
        String text = new String(header, java.nio.charset.StandardCharsets.US_ASCII);
        return "070701".equals(text) || "070702".equals(text) || "070707".equals(text);
    }

    static boolean looksLikeGzip(File file) throws IOException {
        byte[] header = readHeader(file, 2);
        return header.length >= 2 && (header[0] & 0xff) == 0x1f && (header[1] & 0xff) == 0x8b;
    }

    private static File gunzip(Context context, File input) throws IOException {
        File output = new File(context.getCacheDir(), "unidrop-gzip-" + UUID.randomUUID() + ".cpio");
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

    private static byte[] readHeader(File file, int length) throws IOException {
        byte[] header = new byte[length];
        try (FileInputStream input = new FileInputStream(file)) {
            int read = input.read(header);
            if (read <= 0) {
                return new byte[0];
            }
            if (read == length) {
                return header;
            }
            byte[] partial = new byte[read];
            System.arraycopy(header, 0, partial, 0, read);
            return partial;
        }
    }
}
