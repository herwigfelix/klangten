// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
// Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

package it.sixdots.klangten;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

// Klangten 0.4: while the background player or the playlist plays (or is
// paused), a foreground service of the media playback type keeps the app
// alive with the screen locked, so playback goes on and the headset buttons
// reach it. Host.mediaNowPlaying starts, updates and stops it; the
// notification shows what plays and opens Klangten.
public final class PlaybackService extends Service {
    private static final String TAG = "Klangten";
    private static final String CHANNEL = "playback";
    private static final int NOTIFICATION = 4301;
    private static final String EXTRA_TITLE = "title";
    private static final String EXTRA_PLAYING = "playing";
    private static volatile boolean running;

    // state: 0 nothing (stops the service), 1 playing, 2 paused.
    static void update(Context context, String title, int state) {
        if (context == null) return;
        try {
            Intent intent = new Intent(context, PlaybackService.class);
            if (state == 0) {
                if (running) context.stopService(intent);
                return;
            }
            intent.putExtra(EXTRA_TITLE, title);
            intent.putExtra(EXTRA_PLAYING, state == 1);
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
            else context.startService(intent);
        } catch (RuntimeException e) {
            // Android 12 and newer refuse a start from the background; playback
            // goes on, only without the guard.
            Log.w(TAG, "Playback service not started: " + e);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String title = intent != null ? intent.getStringExtra(EXTRA_TITLE) : null;
        boolean playing = intent != null && intent.getBooleanExtra(EXTRA_PLAYING, true);
        Notification notification = notification(title == null || title.isEmpty() ? "Klangten" : title, playing);
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            } else {
                startForeground(NOTIFICATION, notification);
            }
            running = true;
        } catch (RuntimeException e) {
            Log.w(TAG, "Playback service could not go to the foreground: " + e);
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification notification(String title, boolean playing) {
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            if (manager != null && manager.getNotificationChannel(CHANNEL) == null) {
                NotificationChannel channel = new NotificationChannel(CHANNEL,
                        "de".equals(java.util.Locale.getDefault().getLanguage()) ? "Wiedergabe" : "Playback", NotificationManager.IMPORTANCE_LOW);
                channel.setShowBadge(false);
                manager.createNotificationChannel(channel);
            }
            builder = new Notification.Builder(this, CHANNEL);
        } else {
            builder = new Notification.Builder(this);
        }
        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent content = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return builder
                .setSmallIcon(playing ? android.R.drawable.ic_media_play : android.R.drawable.ic_media_pause)
                .setContentTitle(title)
                .setContentText("Klangten")
                .setContentIntent(content)
                .setOngoing(true)
                .setShowWhen(false)
                .build();
    }
}
