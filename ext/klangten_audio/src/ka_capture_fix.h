/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * GNU General Public License, version 3.
 *
 * Microphone recordings are taken in stereo. A phone with one microphone
 * still answers a stereo request, but Android (AAudio) and iOS (RemoteIO)
 * then fill only the left channel and leave the right one silent, so every
 * voice message was heard on the left only. A phone with a real stereo
 * microphone fills both.
 *
 * ka_capture_center() tells the two apart by the signal itself: once one
 * channel carries sound while the other stays dead (below -100 dB), the
 * recording counts as mono for the rest of its life and the live channel is
 * written to both sides, i.e. into the middle. Real stereo microphones never
 * leave one side that quiet, so their recordings stay untouched. The decision
 * is sticky, so a recording does not flip between the two modes at quiet
 * moments.
 *
 * Header only, so that the self test can check it without a sound device.
 */
#ifndef KA_CAPTURE_FIX_H
#define KA_CAPTURE_FIX_H

#define KA_CAPTURE_UNDECIDED 0
#define KA_CAPTURE_STEREO 1
#define KA_CAPTURE_LEFT_ONLY 2
#define KA_CAPTURE_RIGHT_ONLY 3

#define KA_CAPTURE_DEAD 1e-5f      /* -100 dBFS: nothing a microphone delivers */
#define KA_CAPTURE_LIVE 1e-3f      /*  -60 dBFS: clearly sound, not noise floor */

static inline float ka_capture_abs(float v) { return v < 0 ? -v : v; }

/* in/out: interleaved float frames (out may equal in). state: one of the
 * KA_CAPTURE_* values, kept by the caller per recording, starting at
 * KA_CAPTURE_UNDECIDED. Only stereo input is ever changed. */
static inline void ka_capture_center(const float *in, float *out, int frames, int chans, int *state) {
    int i;
    if (chans != 2) {
        if (out != in) for (i = 0; i < frames * chans; i++) out[i] = in[i];
        return;
    }
    {
        float pl = 0, pr = 0;
        int src = -1;
        if (*state == KA_CAPTURE_UNDECIDED) {
            for (i = 0; i < frames; i++) {
                float l = ka_capture_abs(in[2 * i]), r = ka_capture_abs(in[2 * i + 1]);
                if (l > pl) pl = l;
                if (r > pr) pr = r;
            }
            if (pl >= KA_CAPTURE_LIVE && pr <= KA_CAPTURE_DEAD) *state = KA_CAPTURE_LEFT_ONLY;
            else if (pr >= KA_CAPTURE_LIVE && pl <= KA_CAPTURE_DEAD) *state = KA_CAPTURE_RIGHT_ONLY;
            else if (pl >= KA_CAPTURE_LIVE && pr >= KA_CAPTURE_LIVE) *state = KA_CAPTURE_STEREO;
            /* Still undecided (quiet so far): a dead side gets the other one,
             * so even the first breath is not on one side. */
            else if (pr <= KA_CAPTURE_DEAD) src = 0;
            else if (pl <= KA_CAPTURE_DEAD) src = 1;
        }
        if (*state == KA_CAPTURE_LEFT_ONLY) src = 0;
        if (*state == KA_CAPTURE_RIGHT_ONLY) src = 1;
        if (src >= 0) {
            for (i = 0; i < frames; i++) {
                float v = in[2 * i + src];
                out[2 * i] = v;
                out[2 * i + 1] = v;
            }
        } else if (out != in) {
            for (i = 0; i < frames * 2; i++) out[i] = in[i];
        }
    }
}

#endif
