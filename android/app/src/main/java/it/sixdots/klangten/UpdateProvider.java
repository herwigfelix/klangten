// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// Hands the downloaded update to the system package installer.
//
// Since Android 7 an app may not pass file:// URIs to other apps, and the
// package installer runs in its own process. Instead of pulling in AndroidX
// for its FileProvider, this provider serves exactly one file read-only:
// cache/updates/Klangten.apk, which Host.installPackage copies there after the
// Ruby core has checked its size and SHA-256. Nothing else is reachable.
package it.sixdots.klangten;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;

public final class UpdateProvider extends ContentProvider {
    static final String AUTHORITY = "it.sixdots.klangten.updates";
    static final String FILE_NAME = "Klangten.apk";
    static final String MIME = "application/vnd.android.package-archive";

    static Uri uri() {
        return Uri.parse("content://" + AUTHORITY + "/" + FILE_NAME);
    }

    static File file(android.content.Context context) {
        return new File(new File(context.getCacheDir(), "updates"), FILE_NAME);
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    private File served(Uri uri) throws FileNotFoundException {
        if (uri == null || !FILE_NAME.equals(uri.getLastPathSegment())) {
            throw new FileNotFoundException(String.valueOf(uri));
        }
        File f = file(getContext());
        if (!f.isFile()) throw new FileNotFoundException(f.getPath());
        return f;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (mode != null && !mode.equals("r")) throw new SecurityException("read-only");
        return ParcelFileDescriptor.open(served(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        return MIME;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        File f;
        try {
            f = served(uri);
        } catch (FileNotFoundException e) {
            return null;
        }
        MatrixCursor cursor = new MatrixCursor(new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        cursor.addRow(new Object[] {FILE_NAME, f.length()});
        return cursor;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException();
    }
}
