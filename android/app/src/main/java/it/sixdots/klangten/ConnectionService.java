// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Klangten: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
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

// Klangten keeps its connection to the Klango server while it is in the
// background, without Google's push service: a foreground service of the
// remote messaging type. Android 15 and newer cut the network of an app in
// the background unless such a service runs, and freeze the process; with it
// the notification service (src/eapi/notifications.rb) keeps its long poll
// open and new notifications reach the user as system notifications
// (Host.postNotification). The service shows a silent, permanent
// notification, as Android requires. Started and stopped from Ruby
// (src/eapi/background_connection.rb) through Host.connectionService.
public final class ConnectionService extends Service {
    private static final String TAG = "Klangten";
    static final String CHANNEL = "connection";
    private static final int NOTIFICATION = 4302;
    private static final String EXTRA_TEXT = "text";
    private static volatile boolean running;

    static boolean running() {
        return running;
    }

    // on: start (or update the text), off: stop. Starting is only allowed
    // while Klangten is in front (Android 12 and newer); Ruby calls it then.
    static boolean update(Context context, String text, boolean on) {
        if (context == null) return false;
        try {
            Intent intent = new Intent(context, ConnectionService.class);
            if (!on) {
                if (running) context.stopService(intent);
                return true;
            }
            intent.putExtra(EXTRA_TEXT, text);
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent);
            else context.startService(intent);
            return true;
        } catch (RuntimeException e) {
            Log.w(TAG, "Connection service not started: " + e);
            return false;
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String text = intent != null ? intent.getStringExtra(EXTRA_TEXT) : null;
        if (text == null || text.isEmpty()) text = "Klangten";
        Notification notification = notification(text);
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
            } else {
                startForeground(NOTIFICATION, notification);
            }
            running = true;
        } catch (RuntimeException e) {
            Log.w(TAG, "Connection service could not go to the foreground: " + e);
            stopSelf();
        }
        // Not sticky: without the Ruby core (started by the activity) a
        // restarted service would have nothing to keep alive.
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

    private Notification notification(String text) {
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= 26) {
            if (manager != null && manager.getNotificationChannel(CHANNEL) == null) {
                boolean german = "de".equals(java.util.Locale.getDefault().getLanguage());
                NotificationChannel channel = new NotificationChannel(CHANNEL,
                        german ? "Verbindung" : "Connection", NotificationManager.IMPORTANCE_MIN);
                channel.setShowBadge(false);
                channel.setSound(null, null);
                manager.createNotificationChannel(channel);
            }
            builder = new Notification.Builder(this, CHANNEL);
        } else {
            builder = new Notification.Builder(this);
        }
        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent content = PendingIntent.getActivity(this, 1, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return builder
                .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
                .setContentTitle("Klangten")
                .setContentText(text)
                .setContentIntent(content)
                .setOngoing(true)
                .setShowWhen(false)
                .build();
    }
}
