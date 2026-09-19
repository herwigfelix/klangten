// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// Full-screen touch surface. Recognises the same gesture vocabulary as the iOS
// host (swipes and taps with one to four fingers, double taps, long press) and
// pushes the same names ("gesture:two_finger_swipe_up", ...) into the input
// queue; src/platforms/ios/ui/touchinput.rb maps them to keys. TalkBack must be
// off: with explore-by-touch the system would consume these touches.
package it.sixdots.klangten;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.view.MotionEvent;
import android.view.View;

final class GestureView extends View {
    private static final long DOUBLE_TAP_MS = 300;
    private static final long LONG_PRESS_MS = 600;
    private static final String[] PREFIX = {"", "", "two_finger_", "three_finger_", "four_finger_"};

    private final float swipeDistance;
    private final float tapSlop;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private int fingers;
    private float startX, startY, lastX, lastY;
    private long downTime;
    private boolean longPressed;
    // Once the first finger lifts, the centroid of the rest would jump; the
    // gesture is judged by the movement up to that moment.
    private boolean lifting;
    private int pendingTaps;
    private int pendingFingers;
    private final Runnable flushTaps = this::flushTaps;
    private final Runnable longPress = () -> {
        if (fingers == 1 && !moved()) {
            longPressed = true;
            Host.pushGesture("long_press");
        }
    };

    GestureView(Context context) {
        super(context);
        float density = context.getResources().getDisplayMetrics().density;
        swipeDistance = 48 * density;
        tapSlop = 16 * density;
        setFocusable(true);
        setFocusableInTouchMode(true);
        setContentDescription("Klangten");
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                fingers = 1;
                longPressed = false;
                lifting = false;
                downTime = event.getEventTime();
                startX = lastX = event.getX();
                startY = lastY = event.getY();
                handler.postDelayed(longPress, LONG_PRESS_MS);
                return true;
            case MotionEvent.ACTION_POINTER_DOWN:
                fingers = Math.max(fingers, Math.min(event.getPointerCount(), 4));
                handler.removeCallbacks(longPress);
                // Measure the movement of the whole hand from here on.
                startX = lastX = centroidX(event);
                startY = lastY = centroidY(event);
                return true;
            case MotionEvent.ACTION_POINTER_UP:
                lifting = true;
                return true;
            case MotionEvent.ACTION_MOVE:
                if (lifting) return true;
                lastX = centroidX(event);
                lastY = centroidY(event);
                if (moved()) handler.removeCallbacks(longPress);
                return true;
            case MotionEvent.ACTION_UP:
                handler.removeCallbacks(longPress);
                if (!lifting) {
                    lastX = event.getX();
                    lastY = event.getY();
                }
                if (!longPressed) finish();
                return true;
            case MotionEvent.ACTION_CANCEL:
                handler.removeCallbacks(longPress);
                return true;
            default:
                return true;
        }
    }

    private boolean moved() {
        return Math.hypot(lastX - startX, lastY - startY) > tapSlop;
    }

    private void finish() {
        float dx = lastX - startX, dy = lastY - startY;
        if (Math.abs(dx) >= swipeDistance || Math.abs(dy) >= swipeDistance) {
            String direction = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up");
            Host.pushGesture(PREFIX[fingers] + "swipe_" + direction);
            return;
        }
        if (moved()) return;
        // Taps: wait briefly to tell single from double taps.
        if (pendingTaps > 0 && pendingFingers != fingers) flushTaps();
        pendingFingers = fingers;
        pendingTaps++;
        handler.removeCallbacks(flushTaps);
        if (pendingTaps >= 2) flushTaps();
        else handler.postDelayed(flushTaps, DOUBLE_TAP_MS);
    }

    private void flushTaps() {
        handler.removeCallbacks(flushTaps);
        if (pendingTaps == 0) return;
        String name = PREFIX[pendingFingers] + (pendingTaps >= 2 ? "double_tap" : "tap");
        pendingTaps = 0;
        // A single one-finger tap has no meaning (as on iOS), so it is not sent.
        if (!name.equals("tap")) Host.pushGesture(name);
    }

    private static float centroidX(MotionEvent e) {
        float sum = 0;
        for (int i = 0; i < e.getPointerCount(); i++) sum += e.getX(i);
        return sum / e.getPointerCount();
    }

    private static float centroidY(MotionEvent e) {
        float sum = 0;
        for (int i = 0; i < e.getPointerCount(); i++) sum += e.getY(i);
        return sum / e.getPointerCount();
    }
}
