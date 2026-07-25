package com.unidrop.receiver;

import android.net.Uri;

public final class SavedFile {
    public final String displayName;
    public final String displayPath;
    public final String mimeType;
    public final Uri uri;

    public SavedFile(String displayName, String displayPath, String mimeType, Uri uri) {
        this.displayName = displayName;
        this.displayPath = displayPath;
        this.mimeType = mimeType;
        this.uri = uri;
    }
}
