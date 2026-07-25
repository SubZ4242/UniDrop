package com.unidrop.receiver;

import android.content.Context;

import java.io.EOFException;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

public final class CpioExtractor {
    private CpioExtractor() {
    }

    public static List<String> extract(Context context, File cpioFile) throws IOException {
        List<String> saved = new ArrayList<>();
        try (RandomAccessFile archive = new RandomAccessFile(cpioFile, "r")) {
            while (archive.getFilePointer() < archive.length()) {
                String magic = readText(archive, 6, true);
                if (magic.isEmpty()) {
                    break;
                }
                CpioEntry entry;
                if ("070701".equals(magic) || "070702".equals(magic)) {
                    entry = readNewAsciiEntry(archive);
                } else if ("070707".equals(magic)) {
                    entry = readOldAsciiEntry(archive);
                } else if (!saved.isEmpty()) {
                    break;
                } else {
                    throw new IOException("Unsupported CPIO magic " + magic);
                }

                if ("TRAILER!!!".equals(entry.name)) {
                    break;
                }
                String safeName = DownloadWriter.safeFileName(entry.name);
                if (safeName.isEmpty() || entry.directory) {
                    skip(archive, entry.size + entry.dataPadding);
                    continue;
                }

                File staged = new File(context.getCacheDir(), "unidrop-file-" + UUID.randomUUID());
                try {
                    copyEntryToFile(archive, staged, entry.size);
                    skip(archive, entry.dataPadding);
                    repairKnownOneByteImageShift(staged, safeName);
                    saved.add(DownloadWriter.save(context, safeName, staged));
                } finally {
                    if (!staged.delete() && staged.exists()) {
                        // best effort cleanup only
                    }
                }
            }
        }
        return saved;
    }

    private static CpioEntry readNewAsciiEntry(RandomAccessFile archive) throws IOException {
        String[] fields = new String[13];
        for (int i = 0; i < fields.length; i++) {
            fields[i] = readText(archive, 8, false);
        }
        long mode = parseHex(fields[1]);
        long size = parseHex(fields[6]);
        long nameSize = parseHex(fields[11]);
        String name = readName(archive, nameSize);
        long standardPadding = pad4(110 + nameSize);
        long namePadding = chooseNewAsciiNamePadding(archive, name, size, standardPadding);
        if (namePadding >= 0) {
            skip(archive, namePadding);
        } else {
            archive.seek(Math.max(0, archive.getFilePointer() + namePadding));
        }
        return new CpioEntry(name, size, (mode & 0x4000) == 0x4000, pad4(size));
    }

    private static CpioEntry readOldAsciiEntry(RandomAccessFile archive) throws IOException {
        readText(archive, 6, false);
        readText(archive, 6, false);
        long mode = parseOctal(readText(archive, 6, false));
        readText(archive, 6, false);
        readText(archive, 6, false);
        readText(archive, 6, false);
        readText(archive, 6, false);
        readText(archive, 11, false);
        long nameSize = parseOctal(readText(archive, 6, false));
        long size = parseOctal(readText(archive, 11, false));
        String name = readName(archive, nameSize);
        skip(archive, (76 + nameSize) % 2);
        return new CpioEntry(name, size, (mode & 0x4000) == 0x4000, size % 2);
    }

    private static String readName(RandomAccessFile archive, long size) throws IOException {
        if (size < 0 || size > 1024 * 1024) {
            throw new IOException("Invalid CPIO name size " + size);
        }
        byte[] bytes = new byte[(int) size];
        archive.readFully(bytes);
        int length = bytes.length;
        if (length > 0 && bytes[length - 1] == 0) {
            length--;
        } else if (length > 0) {
            archive.seek(archive.getFilePointer() - 1);
            length--;
        }
        return new String(bytes, 0, Math.max(0, length), StandardCharsets.UTF_8);
    }

    private static String readText(RandomAccessFile archive, int size, boolean allowEof) throws IOException {
        byte[] bytes = new byte[size];
        int read = archive.read(bytes);
        if (read < 0 && allowEof) {
            return "";
        }
        if (read != size) {
            throw new EOFException();
        }
        return new String(bytes, StandardCharsets.US_ASCII);
    }

    private static long chooseNewAsciiNamePadding(RandomAccessFile archive, String name, long entrySize, long standardPadding) throws IOException {
        long dataStart = archive.getFilePointer();
        long[] candidates = standardPadding == 0 ? new long[] {0, -1} : new long[] {standardPadding, 0, -1};
        long bestPadding = standardPadding;
        int bestScore = -1;
        for (long candidate : candidates) {
            int score = 0;
            if (fileDataLooksValid(archive, name, dataStart + candidate)) score += 4;
            if (nextMagicLooksValid(archive, dataStart + candidate + entrySize + pad4(entrySize))) score += 2;
            if (candidate == standardPadding) score += 1;
            if (score > bestScore) {
                bestScore = score;
                bestPadding = candidate;
            }
        }
        archive.seek(dataStart);
        return bestPadding;
    }

    private static boolean fileDataLooksValid(RandomAccessFile archive, String name, long position) throws IOException {
        if (position < 0 || position >= archive.length()) {
            return false;
        }
        long original = archive.getFilePointer();
        try {
            archive.seek(position);
            byte[] header = new byte[16];
            int read = archive.read(header);
            if (looksLikeKnownSignature(header, read)) {
                return true;
            }
            String lower = name.toLowerCase(Locale.ROOT);
            return (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) && read >= 2 && (header[0] & 0xff) == 0xff && (header[1] & 0xff) == 0xd8
                || lower.endsWith(".png") && read >= 8 && (header[0] & 0xff) == 0x89 && header[1] == 0x50 && header[2] == 0x4e && header[3] == 0x47
                || lower.endsWith(".gif") && read >= 6 && new String(header, 0, 6, StandardCharsets.US_ASCII).startsWith("GIF")
                || (lower.endsWith(".heic") || lower.endsWith(".heif")) && read >= 12 && new String(header, 4, 4, StandardCharsets.US_ASCII).equals("ftyp");
        } finally {
            archive.seek(original);
        }
    }

    private static boolean nextMagicLooksValid(RandomAccessFile archive, long position) throws IOException {
        if (position < 0 || position > archive.length()) {
            return false;
        }
        if (position == archive.length()) {
            return true;
        }
        long original = archive.getFilePointer();
        try {
            archive.seek(position);
            byte[] magic = new byte[6];
            int read = archive.read(magic);
            if (read == 0 || read < 0) {
                return true;
            }
            if (read != 6) {
                return false;
            }
            String text = new String(magic, StandardCharsets.US_ASCII);
            return "070701".equals(text) || "070702".equals(text) || "070707".equals(text);
        } finally {
            archive.seek(original);
        }
    }

    private static boolean looksLikeKnownSignature(byte[] header, int read) {
        return read >= 2 && (header[0] & 0xff) == 0xff && (header[1] & 0xff) == 0xd8
            || read >= 8 && (header[0] & 0xff) == 0x89 && header[1] == 0x50 && header[2] == 0x4e && header[3] == 0x47
            || read >= 6 && new String(header, 0, 6, StandardCharsets.US_ASCII).startsWith("GIF")
            || read >= 12 && new String(header, 4, 4, StandardCharsets.US_ASCII).equals("ftyp");
    }

    private static void copyEntryToFile(RandomAccessFile archive, File destination, long bytes) throws IOException {
        if (bytes < 0) {
            throw new IOException("Invalid CPIO file size " + bytes);
        }
        byte[] buffer = new byte[128 * 1024];
        long remaining = bytes;
        try (FileOutputStream output = new FileOutputStream(destination)) {
            while (remaining > 0) {
                int read = archive.read(buffer, 0, (int) Math.min(buffer.length, remaining));
                if (read < 0) {
                    throw new EOFException();
                }
                output.write(buffer, 0, read);
                remaining -= read;
            }
        }
    }

    private static void repairKnownOneByteImageShift(File file, String name) throws IOException {
        if (file.length() < 4 || file.length() > 256L * 1024L * 1024L) {
            return;
        }
        byte[] bytes = java.nio.file.Files.readAllBytes(file.toPath());
        Byte missing = null;
        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".png") && bytes.length >= 8 && bytes[0] == 0x50 && bytes[1] == 0x4e && bytes[2] == 0x47) {
            missing = (byte) 0x89;
        } else if ((lower.endsWith(".jpg") || lower.endsWith(".jpeg")) && bytes.length >= 2 && (bytes[0] & 0xff) == 0xd8 && (bytes[1] & 0xff) == 0xff) {
            missing = (byte) 0xff;
        }
        if (missing == null) {
            return;
        }
        byte[] repaired = new byte[bytes.length];
        repaired[0] = missing;
        System.arraycopy(bytes, 0, repaired, 1, bytes.length - 1);
        java.nio.file.Files.write(file.toPath(), repaired);
    }

    private static void skip(RandomAccessFile archive, long bytes) throws IOException {
        if (bytes < 0) {
            archive.seek(Math.max(0, archive.getFilePointer() + bytes));
            return;
        }
        archive.seek(archive.getFilePointer() + bytes);
    }

    private static long parseHex(String value) {
        return Long.parseLong(value.trim(), 16);
    }

    private static long parseOctal(String value) {
        return Long.parseLong(value.trim(), 8);
    }

    private static long pad4(long value) {
        return (4 - value % 4) % 4;
    }

    private static final class CpioEntry {
        final String name;
        final long size;
        final boolean directory;
        final long dataPadding;

        CpioEntry(String name, long size, boolean directory, long dataPadding) {
            this.name = name;
            this.size = size;
            this.directory = directory;
            this.dataPadding = dataPadding;
        }
    }
}
