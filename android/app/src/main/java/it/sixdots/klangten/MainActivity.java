// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// The Android host: a full-screen gesture surface plus a hidden text field for
// the system keyboard, and the embedded Ruby core on its own thread
// (app/ruby/android_boot.rb). Klangten speaks for itself; TalkBack must be off.
//
// For automated tests the entry script and gestures can be driven by intents:
//   adb shell am start -n it.sixdots.klangten/.MainActivity --es entry probe.rb
//   adb shell am start -n it.sixdots.klangten/.MainActivity --es gesture swipe_right
package it.sixdots.klangten;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.text.InputType;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;

import java.io.File;

public final class MainActivity extends Activity {
    private static final String TAG = "Klangten";
    // CRuby expects a large machine stack; the default thread stack is too small.
    private static final long RUBY_STACK = 64L * 1024 * 1024;
    private static boolean started;

    private GestureView surface;
    private EditText textField;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Host.attach(this);
        FrameLayout root = new FrameLayout(this);
        surface = new GestureView(this);
        textField = new EditText(this);
        textField.setAlpha(0f);
        textField.setSingleLine(true);
        textField.setInputType(InputType.TYPE_CLASS_TEXT);
        textField.setImeOptions(EditorInfo.IME_ACTION_DONE);
        textField.setOnEditorActionListener((view, action, event) -> {
            Host.pushInput("ktext:" + textField.getText());
            textField.setText("");
            hideKeyboard();
            return true;
        });
        root.addView(textField, new FrameLayout.LayoutParams(1, 1));
        root.addView(surface, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
        surface.requestFocus();
        handleIntent(getIntent());
        if (started) return;
        started = true;
        String entry = getIntent().getStringExtra("entry");
        new Thread(null, () -> runRuby(entry == null ? "android_boot.rb" : entry), "ruby", RUBY_STACK).start();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleIntent(intent);
    }

    private void handleIntent(Intent intent) {
        String gesture = intent == null ? null : intent.getStringExtra("gesture");
        if (gesture != null) Host.pushGesture(gesture);
    }

    @Override
    protected void onResume() {
        super.onResume();
        Host.pushInput("active:1");
    }

    @Override
    protected void onPause() {
        Host.pushInput("active:0");
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        Host.detach(this);
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        if (code == Host.MICROPHONE_REQUEST) {
            Host.microphoneResult(results.length > 0 && results[0] == android.content.pm.PackageManager.PERMISSION_GRANTED);
        }
    }

    // The back gesture/button is Escape inside Klangten, not "leave the app".
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            Host.pushGesture("two_finger_swipe_left");
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    void showKeyboard() {
        textField.setText("");
        textField.requestFocus();
        InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        imm.showSoftInput(textField, InputMethodManager.SHOW_IMPLICIT);
        Host.pushInput("ksys:1");
    }

    void hideKeyboard() {
        InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        imm.hideSoftInputFromWindow(textField.getWindowToken(), 0);
        surface.requestFocus();
        Host.pushInput("ksys:0");
    }

    boolean keyboardVisible() {
        View decor = getWindow().getDecorView();
        WindowInsets insets = decor.getRootWindowInsets();
        return insets != null && insets.isVisible(WindowInsets.Type.ime());
    }

    private void runRuby(String entry) {
        try {
            File root = RubyRuntime.prepare(this);
            int status = RubyRuntime.boot(root.getAbsolutePath(), new File(root, entry).getAbsolutePath(),
                    getApplicationInfo().nativeLibraryDir, getFilesDir().getAbsolutePath());
            Log.i(TAG, "Ruby finished with status " + status);
        } catch (Throwable e) {
            Log.e(TAG, "Ruby failed", e);
        }
    }
}
