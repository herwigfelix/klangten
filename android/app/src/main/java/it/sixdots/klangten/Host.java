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

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
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
    private static volatile String engineId = "";
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

    static void pushToken(String token) {
        if (debug) Log.d(TAG + "-input", token);
        pushInput(token);
    }

    static void attach(MainActivity current) {
        activity = current;
        if (app == null) {
            app = current.getApplicationContext();
            debug = (app.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0;
            createSpeech("");
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
            if (!ttsReady) waitForSpeech();
            if (ttsReady && tts.getVoices() != null) {
                List<Voice> voices = new ArrayList<>(tts.getVoices());
                // The voices of the phone's own language first; the rest, in
                // alphabetical order, follows.
                String own = Locale.getDefault().getLanguage();
                Collections.sort(voices, (a, b) -> {
                    boolean ownA = a.getLocale().getLanguage().equals(own);
                    boolean ownB = b.getLocale().getLanguage().equals(own);
                    if (ownA != ownB) return ownA ? -1 : 1;
                    return voiceLabel(a).compareToIgnoreCase(voiceLabel(b));
                });
                for (Voice voice : voices) {
                    if (voice.isNetworkConnectionRequired()) continue;
                    JSONObject o = new JSONObject();
                    o.put("id", voice.getName());
                    o.put("name", voiceLabel(voice));
                    o.put("language", voice.getLocale().toLanguageTag());
                    list.put(o);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "voices", e);
        }
        return list.toString();
    }

    // "Deutsch (Deutschland) - deb, hohe Qualitaet": the raw names Android
    // reports ("de-de-x-deb-local") mean nothing to a listener.
    private static String voiceLabel(Voice voice) {
        String language = voice.getLocale().getDisplayName();
        String name = voice.getName();
        String variant = name;
        int marker = name.indexOf("-x-");
        if (marker >= 0) {
            variant = name.substring(marker + 3);
            if (variant.endsWith("-local")) variant = variant.substring(0, variant.length() - 6);
            if (variant.endsWith("-network")) variant = variant.substring(0, variant.length() - 8);
        } else if (name.toLowerCase(Locale.ROOT).startsWith(voice.getLocale().toLanguageTag().toLowerCase(Locale.ROOT))) {
            variant = name.substring(Math.min(name.length(), voice.getLocale().toLanguageTag().length()));
            variant = variant.replaceAll("^[-_]+", "");
        }
        String quality = voice.getQuality() >= Voice.QUALITY_VERY_HIGH ? "+" : "";
        return variant.isEmpty() ? language : language + " - " + variant + quality;
    }

    // The engines installed on the device (Google, Samsung, Vocalizer, ...).
    static String speechEnginesJson() {
        JSONArray list = new JSONArray();
        try {
            if (tts == null) return list.toString();
            for (TextToSpeech.EngineInfo engine : tts.getEngines()) {
                JSONObject o = new JSONObject();
                o.put("id", engine.name);
                o.put("name", engine.label == null || engine.label.isEmpty() ? engine.name : engine.label);
                list.put(o);
            }
        } catch (Exception e) {
            Log.w(TAG, "engines", e);
        }
        return list.toString();
    }

    static String speechEngine() {
        if (!engineId.isEmpty()) return engineId;
        try {
            return tts == null ? "" : tts.getDefaultEngine();
        } catch (Exception e) {
            return "";
        }
    }

    // Switching engines means a new TextToSpeech instance; the voices change with it.
    static int speechSetEngine(String id) {
        if (id == null) id = "";
        if (id.equals(speechEngine())) return 1;
        try {
            if (tts != null) {
                tts.stop();
                tts.shutdown();
            }
        } catch (Exception ignored) {
        }
        createSpeech(id);
        waitForSpeech();
        return ttsReady ? 1 : 0;
    }

    private static void createSpeech(String id) {
        engineId = id == null ? "" : id;
        ttsReady = false;
        tts = engineId.isEmpty()
                ? new TextToSpeech(app, status -> speechInitialised(status))
                : new TextToSpeech(app, status -> speechInitialised(status), engineId);
    }

    private static void speechInitialised(int status) {
        ttsReady = status == TextToSpeech.SUCCESS;
        Log.i(TAG, "TextToSpeech ready: " + ttsReady + (engineId.isEmpty() ? "" : " (" + engineId + ")"));
    }

    // rate, volume and pitch are 0..100 with 50 as the default, like on iOS.
    static void speechSpeak(String text, String voiceId, int rate, int volume, int pitch, boolean interrupt) {
        if (tts == null || text == null || text.isEmpty()) return;
        // What Klangten says, for tests on the emulator: adb logcat -s Klangten-speech
        if (debug) Log.d(TAG + "-speech", "[" + text.length() + "] " + text);
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

    // --- self-update -----------------------------------------------------------------------

    // Hands a downloaded and already verified APK to the system package installer.
    // 1 = the installer was opened, 2 = Klangten may not install apps yet (the
    // settings page for that permission was opened instead), 0 = failure.
    static int installPackage(String path) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    && !app.getPackageManager().canRequestPackageInstalls()) {
                Intent settings = new Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:" + app.getPackageName()));
                settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                app.startActivity(settings);
                return 2;
            }
            java.io.File source = new java.io.File(path);
            java.io.File target = UpdateProvider.file(app);
            java.io.File dir = target.getParentFile();
            if (dir != null && !dir.isDirectory() && !dir.mkdirs()) return 0;
            try (java.io.InputStream in = new java.io.FileInputStream(source);
                 java.io.OutputStream out = new java.io.FileOutputStream(target)) {
                byte[] buffer = new byte[64 * 1024];
                int n;
                while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
            }
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(UpdateProvider.uri(), UpdateProvider.MIME);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            app.startActivity(intent);
            return 1;
        } catch (Exception e) {
            Log.w(TAG, "installPackage " + path, e);
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
