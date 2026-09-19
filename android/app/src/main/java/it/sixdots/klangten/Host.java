// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// Host services for the embedded Ruby core, called from host_bridge.c
// (elten_host_*). The counterpart of EltenHostBridge.swift on iOS: speech,
// clipboard, URLs, microphone permission, locale and the system keyboard.
// All methods are called from Ruby threads; UI work is posted to the main thread.
package it.sixdots.klangten;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.speech.tts.Voice;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

final class Host {
    private static final String TAG = "Klangten";
    static final int MICROPHONE_REQUEST = 4201;

    private static final Handler main = new Handler(Looper.getMainLooper());
    private static volatile MainActivity activity;
    private static Context app;
    private static TextToSpeech tts;
    private static volatile boolean ttsReady;
    private static final AtomicInteger utterances = new AtomicInteger();
    private static volatile CountDownLatch microphoneLatch;
    private static volatile boolean microphoneGranted;
    // Debug builds log gestures and spoken text for tests on the emulator;
    // release builds never put what Klangten reads aloud into the log.
    private static boolean debug;

    static {
        // pushInput is native: the library must be in before the first gesture.
        RubyRuntime.load();
    }

    private Host() {}

    static native void pushInput(String token);

    static void pushGesture(String name) {
        if (debug) Log.d(TAG + "-input", name);
        pushInput("gesture:" + name);
    }

    static void attach(MainActivity current) {
        activity = current;
        if (app == null) {
            app = current.getApplicationContext();
            debug = (app.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0;
            tts = new TextToSpeech(app, status -> {
                ttsReady = status == TextToSpeech.SUCCESS;
                Log.i(TAG, "TextToSpeech ready: " + ttsReady);
            });
        }
    }

    static void detach(MainActivity current) {
        if (activity == current) activity = null;
    }

    // --- speech (TextToSpeech) ----------------------------------------------------

    static int speechAvailable() {
        return tts != null ? 1 : 0;
    }

    static String speechVoicesJson() {
        JSONArray list = new JSONArray();
        try {
            if (ttsReady && tts.getVoices() != null) {
                for (Voice voice : tts.getVoices()) {
                    if (voice.isNetworkConnectionRequired()) continue;
                    JSONObject o = new JSONObject();
                    o.put("id", voice.getName());
                    o.put("name", voice.getName());
                    o.put("language", voice.getLocale().toLanguageTag());
                    list.put(o);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "voices", e);
        }
        return list.toString();
    }

    // rate, volume and pitch are 0..100 with 50 as the default, like on iOS.
    static void speechSpeak(String text, String voiceId, int rate, int volume, int pitch, boolean interrupt) {
        if (tts == null || text == null || text.isEmpty()) return;
        // What Klangten says, for tests on the emulator: adb logcat -s Klangten-speech
        if (debug) Log.d(TAG + "-speech", text);
        if (!ttsReady) waitForSpeech();
        if (!voiceId.isEmpty() && tts.getVoices() != null) {
            for (Voice voice : tts.getVoices()) {
                if (voice.getName().equals(voiceId)) {
                    if (!voice.equals(tts.getVoice())) tts.setVoice(voice);
                    break;
                }
            }
        }
        tts.setSpeechRate(scale(rate, 0.35f, 3.5f));
        tts.setPitch(scale(pitch, 0.5f, 2.0f));
        Bundle params = new Bundle();
        params.putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, Math.max(0, Math.min(100, volume)) / 100f);
        tts.speak(text, interrupt ? TextToSpeech.QUEUE_FLUSH : TextToSpeech.QUEUE_ADD, params,
                "k" + utterances.incrementAndGet());
    }

    // 0 -> low, 50 -> 1.0, 100 -> high, geometric so the steps feel even.
    private static float scale(int value, float low, float high) {
        float v = Math.max(0, Math.min(100, value)) / 50f - 1f;
        return (float) (v < 0 ? Math.pow(1f / low, v) : Math.pow(high, v));
    }

    private static void waitForSpeech() {
        for (int i = 0; i < 50 && !ttsReady; i++) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                return;
            }
        }
    }

    static void speechStop() {
        if (tts != null) tts.stop();
    }

    static int speechSpeaking() {
        return tts != null && tts.isSpeaking() ? 1 : 0;
    }

    // --- clipboard -------------------------------------------------------------------

    static String clipboardGet() {
        return onMain(() -> {
            ClipboardManager clipboard = (ClipboardManager) app.getSystemService(Context.CLIPBOARD_SERVICE);
            ClipData clip = clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return "";
            CharSequence text = clip.getItemAt(0).coerceToText(app);
            return text == null ? "" : text.toString();
        }, "");
    }

    static int clipboardSet(String text) {
        main.post(() -> {
            ClipboardManager clipboard = (ClipboardManager) app.getSystemService(Context.CLIPBOARD_SERVICE);
            clipboard.setPrimaryClip(ClipData.newPlainText("Klangten", text));
        });
        return 1;
    }

    // --- system --------------------------------------------------------------------------

    static int openUrl(String url) {
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            app.startActivity(intent);
            return 1;
        } catch (Exception e) {
            Log.w(TAG, "openUrl " + url, e);
            return 0;
        }
    }

    static String locale() {
        return Locale.getDefault().toLanguageTag();
    }

    static String osVersion() {
        return "Android " + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ")";
    }

    static String nativeLibraryDir() {
        return app.getApplicationInfo().nativeLibraryDir;
    }

    static int microphoneRequest(double timeoutSeconds) {
        if (app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) return 1;
        MainActivity current = activity;
        if (current == null) return 0;
        CountDownLatch latch = new CountDownLatch(1);
        microphoneLatch = latch;
        microphoneGranted = false;
        main.post(() -> current.requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, MICROPHONE_REQUEST));
        try {
            latch.await((long) (timeoutSeconds * 1000), TimeUnit.MILLISECONDS);
        } catch (InterruptedException ignored) {
        }
        return microphoneGranted ? 1 : 0;
    }

    static void microphoneResult(boolean granted) {
        microphoneGranted = granted;
        CountDownLatch latch = microphoneLatch;
        if (latch != null) latch.countDown();
    }

    // --- system keyboard ------------------------------------------------------------------

    static void keyboardShow() {
        MainActivity current = activity;
        if (current != null) main.post(current::showKeyboard);
    }

    static void keyboardHide() {
        MainActivity current = activity;
        if (current != null) main.post(current::hideKeyboard);
    }

    static int keyboardVisible() {
        MainActivity current = activity;
        return current != null && current.keyboardVisible() ? 1 : 0;
    }

    private interface Call<T> {
        T run() throws Exception;
    }

    private static <T> T onMain(Call<T> call, T fallback) {
        FutureTask<T> task = new FutureTask<>(call::run);
        main.post(task);
        try {
            return task.get(2, TimeUnit.SECONDS);
        } catch (Exception e) {
            Log.w(TAG, "host call", e);
            return fallback;
        }
    }

    static Activity currentActivity() {
        return activity;
    }
}
