// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// Starts the embedded CRuby. The Ruby files (standard library, Klangten core)
// ship as assets and are copied to the app's files directory once per APK
// version, because Ruby needs real paths for require.
package it.sixdots.klangten;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.res.AssetManager;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

final class RubyRuntime {
    static {
        // BASS needs its JNI_OnLoad (Java VM, audio output) before Ruby opens it via Fiddle.
        try {
            System.loadLibrary("bass");
        } catch (UnsatisfiedLinkError ignored) {
            // Built without scripts/fetch-bass.sh: audio stays unavailable.
        }
        System.loadLibrary("klangten");
    }

    /** Boots Ruby and runs entry; returns its exit status (output goes to logcat). Call once. */
    static native int boot(String rubyRoot, String entry, String nativeLibDir, String filesDir);

    private RubyRuntime() {}

    /** Loads the native libraries (the static block above) if nothing has yet. */
    static void load() {}

    /** Copies assets/ruby to files/ruby when the APK changed since the last copy. */
    static File prepare(Context context) throws IOException {
        File root = new File(context.getFilesDir(), "ruby");
        File marker = new File(root, ".apk-version");
        String version = apkVersion(context);
        if (marker.isFile() && version.equals(new String(Files.readAllBytes(marker.toPath()), StandardCharsets.UTF_8))) {
            return root;
        }
        deleteTree(root);
        copyAssets(context.getAssets(), "ruby", root);
        try (OutputStream out = new FileOutputStream(marker)) {
            out.write(version.getBytes(StandardCharsets.UTF_8));
        }
        return root;
    }

    private static String apkVersion(Context context) {
        try {
            PackageInfo info = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
            return info.getLongVersionCode() + "/" + info.lastUpdateTime;
        } catch (Exception e) {
            return "unknown";
        }
    }

    private static void copyAssets(AssetManager assets, String path, File target) throws IOException {
        String[] children = assets.list(path);
        if (children == null || children.length == 0) {
            target.getParentFile().mkdirs();
            try (InputStream in = assets.open(path); OutputStream out = new FileOutputStream(target)) {
                byte[] buffer = new byte[65536];
                int n;
                while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
            }
            return;
        }
        target.mkdirs();
        for (String child : children) copyAssets(assets, path + "/" + child, new File(target, child));
    }

    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }
}
