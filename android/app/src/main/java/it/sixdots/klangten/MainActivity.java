// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// Phase 1 host: starts the embedded Ruby on its own thread and shows what the
// probe script reports. The real UI (self-voicing, gestures) comes later.
package it.sixdots.klangten;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

public final class MainActivity extends Activity {
    private static final String TAG = "Klangten";
    // CRuby expects a large machine stack; the default thread stack is too small.
    private static final long RUBY_STACK = 64L * 1024 * 1024;
    private static boolean started;

    private TextView output;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        output = new TextView(this);
        output.setTextIsSelectable(true);
        output.setPadding(32, 32, 32, 32);
        output.setText("Klangten startet …");
        ScrollView scroll = new ScrollView(this);
        scroll.addView(output);
        setContentView(scroll);
        if (started) return;
        started = true;
        new Thread(null, this::runRuby, "ruby", RUBY_STACK).start();
    }

    private void runRuby() {
        String result;
        long t0 = System.currentTimeMillis();
        try {
            File root = RubyRuntime.prepare(this);
            long t1 = System.currentTimeMillis();
            File report = new File(getFilesDir(), "probe-result.txt");
            report.delete();
            int status = RubyRuntime.boot(root.getAbsolutePath(), new File(root, "probe.rb").getAbsolutePath(),
                    getApplicationInfo().nativeLibraryDir, getFilesDir().getAbsolutePath());
            String lines = report.isFile()
                    ? new String(Files.readAllBytes(report.toPath()), StandardCharsets.UTF_8)
                    : "(kein Ergebnis, siehe logcat -s Klangten-ruby)";
            result = "Dateien bereitgestellt in " + (t1 - t0) + " ms, Ruby lief " + (System.currentTimeMillis() - t1)
                    + " ms, Status " + status + "\n\n" + lines;
        } catch (Throwable e) {
            result = "Fehler: " + e;
        }
        Log.i(TAG, result);
        final String text = result;
        runOnUiThread(() -> output.setText(text));
    }
}
