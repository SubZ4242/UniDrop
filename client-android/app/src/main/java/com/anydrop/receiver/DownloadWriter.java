package com.unidrop.receiver;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.DocumentsContract;
import android.provider.MediaStore;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Locale;

public final class DownloadWriter {
    private DownloadWriter() {
    }

    public static SavedFile save(Context context, String displayName, File source) throws IOException {
        String safeName = safeFileName(displayName);
        if (safeName.isEmpty()) {
            safeName = "unidrop-file";
        }
        SharedPreferences prefs = context.getSharedPreferences(ReceiverService.PREFS, Context.MODE_PRIVATE);
        String tree = prefs.getString(ReceiverService.KEY_OUTPUT_TREE_URI, "");
        if (tree != null && !tree.isEmpty()) {
            return saveDocumentTree(context, Uri.parse(tree), safeName, source);
        }
        if (Build.VERSION.SDK_INT >= 29) {
            return saveMediaStore(context, safeName, source);
        }
        return saveLegacy(safeName, source);
    }

    private static SavedFile saveDocumentTree(Context context, Uri treeUri, String displayName, File source) throws IOException {
        String mimeType = guessMime(displayName);
        Uri treeDocument = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri)
        );
        Uri document = DocumentsContract.createDocument(
            context.getContentResolver(),
            treeDocument,
            mimeType,
            displayName
        );
        if (document == null) {
            throw new IOException("Could not create document in selected folder");
        }
        try (OutputStream output = context.getContentResolver().openOutputStream(document);
             FileInputStream input = new FileInputStream(source)) {
            if (output == null) {
                throw new IOException("Selected folder output stream unavailable");
            }
            byte[] buffer = new byte[128 * 1024];
            int read;
            while ((read = input.read(buffer)) >= 0) {
                output.write(buffer, 0, read);
            }
        }
        return new SavedFile(displayName, "Ausgewählter Ordner/" + displayName, mimeType, document);
    }

    private static SavedFile saveMediaStore(Context context, String displayName, File source) throws IOException {
        ContentResolver resolver = context.getContentResolver();
        String mimeType = guessMime(displayName);
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName);
        values.put(MediaStore.MediaColumns.MIME_TYPE, mimeType);
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/UniDrop");
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);
        Uri uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
        if (uri == null) {
            throw new IOException("MediaStore insert failed");
        }
        try {
            try (OutputStream output = resolver.openOutputStream(uri);
                 FileInputStream input = new FileInputStream(source)) {
                if (output == null) {
                    throw new IOException("MediaStore output stream unavailable");
                }
                byte[] buffer = new byte[128 * 1024];
                int read;
                while ((read = input.read(buffer)) >= 0) {
                    output.write(buffer, 0, read);
                }
            }
            ContentValues done = new ContentValues();
            done.put(MediaStore.MediaColumns.IS_PENDING, 0);
            resolver.update(uri, done, null, null);
            return new SavedFile(displayName, "Downloads/UniDrop/" + displayName, mimeType, uri);
        } catch (IOException exc) {
            resolver.delete(uri, null, null);
            throw exc;
        }
    }

    private static SavedFile saveLegacy(String displayName, File source) throws IOException {
        File directory = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "UniDrop");
        if (!directory.exists() && !directory.mkdirs()) {
            throw new IOException("Could not create " + directory);
        }
        File destination = uniqueFile(new File(directory, displayName));
        try (FileInputStream input = new FileInputStream(source);
             FileOutputStream output = new FileOutputStream(destination)) {
            byte[] buffer = new byte[128 * 1024];
            int read;
            while ((read = input.read(buffer)) >= 0) {
                output.write(buffer, 0, read);
            }
        }
        return new SavedFile(displayName, destination.getAbsolutePath(), guessMime(displayName), Uri.fromFile(destination));
    }

    public static String safeFileName(String name) {
        String normalized = name == null ? "" : name.replace('\\', '/');
        int slash = normalized.lastIndexOf('/');
        if (slash >= 0) {
            normalized = normalized.substring(slash + 1);
        }
        normalized = normalized.replaceAll("[\\x00-\\x1f<>:\"|?*]", "_").trim();
        while (normalized.startsWith(".")) {
            normalized = normalized.substring(1);
        }
        return normalized;
    }

    private static File uniqueFile(File file) {
        if (!file.exists()) {
            return file;
        }
        String name = file.getName();
        String base = name;
        String extension = "";
        int dot = name.lastIndexOf('.');
        if (dot > 0) {
            base = name.substring(0, dot);
            extension = name.substring(dot);
        }
        for (int i = 1; ; i++) {
            File candidate = new File(file.getParentFile(), base + " (" + i + ")" + extension);
            if (!candidate.exists()) {
                return candidate;
            }
        }
    }

    private static String guessMime(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
        if (lower.endsWith(".png")) return "image/png";
        if (lower.endsWith(".gif")) return "image/gif";
        if (lower.endsWith(".heic")) return "image/heic";
        if (lower.endsWith(".mp4")) return "video/mp4";
        if (lower.endsWith(".mov")) return "video/quicktime";
        if (lower.endsWith(".pdf")) return "application/pdf";
        if (lower.endsWith(".txt")) return "text/plain";
        return "application/octet-stream";
    }
}
