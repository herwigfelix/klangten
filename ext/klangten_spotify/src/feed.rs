// Part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
// Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. See the repository's licence.

// feed.rs — the PCM ring buffer between librespot and the host's audio output.
//
// A push/drain ring with backpressure, format, done/cancel, a seek gate
// (`gate`) and a counter of played frames (`played`). Two design points:
//
//   * f32 rather than i16 — BASS takes float samples directly, so a round
//     trip through i16 would only add quantisation;
//   * the consumer side (honour the gate, drain the ring, count played
//     frames) lives here in `read_into`: Klangten feeds a BASS push stream
//     from a Ruby thread that calls ks_read_pcm (ffi.rs), which calls exactly
//     this function.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Default ring capacity (~10 s of stereo at 44.1 kHz) — Spotify playback
/// sets a smaller one when opening a track (open_track: ~2 s).
const RING_MAX: usize = 44100 * 2 * 10;

pub struct PcmFeed {
    state: Mutex<String>,
    /// decoded, interleaved PCM (stereo)
    pcm: Mutex<VecDeque<f32>>,
    fmt: Mutex<Option<(u32, u32)>>,
    cancel: AtomicBool,
    /// Producer finished (end of track). The consumer ends the stream as soon
    /// as the buffer is empty.
    done: AtomicBool,
    /// Seek gate: while set, the consumer side discards everything that
    /// arrives (a short silence) instead of playing stale audio that librespot
    /// had already decoded ahead (otherwise a backward jump would sound like a
    /// jump forward). See the seek handling in engine.rs.
    gate: AtomicBool,
    ring_max: AtomicUsize,
    /// Frames actually PLAYED by the consumer since track start or the last
    /// seek — engine.rs derives the AUDIBLE position from this.
    played: AtomicU64,
}

impl PcmFeed {
    fn new() -> Self {
        PcmFeed {
            state: Mutex::new("init".into()),
            pcm: Mutex::new(VecDeque::new()),
            fmt: Mutex::new(None),
            cancel: AtomicBool::new(false),
            done: AtomicBool::new(false),
            gate: AtomicBool::new(false),
            ring_max: AtomicUsize::new(RING_MAX),
            played: AtomicU64::new(0),
        }
    }

    pub fn new_arc() -> Arc<PcmFeed> {
        Arc::new(PcmFeed::new())
    }

    pub fn is_done(&self) -> bool {
        self.done.load(Ordering::SeqCst)
    }
    pub fn set_format(&self, channels: u32, samplerate: u32) {
        *self.fmt.lock().unwrap() = Some((channels, samplerate));
    }
    pub fn format(&self) -> Option<(u32, u32)> {
        *self.fmt.lock().unwrap()
    }
    pub fn mark_done(&self) {
        self.done.store(true, Ordering::SeqCst);
    }
    pub fn set_state_ext(&self, s: &str) {
        *self.state.lock().unwrap() = s.to_string();
    }
    pub fn state(&self) -> String {
        self.state.lock().unwrap().clone()
    }
    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::SeqCst)
    }
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }
    /// Discards the buffered PCM — on seek, so that librespot does not block
    /// on backpressure and can deliver from the new position.
    pub fn clear_pcm(&self) {
        self.pcm.lock().unwrap().clear();
    }
    pub fn set_gate(&self, on: bool) {
        self.gate.store(on, Ordering::SeqCst);
    }
    pub fn is_gated(&self) -> bool {
        self.gate.load(Ordering::SeqCst)
    }
    pub fn set_ring_max(&self, samples: usize) {
        self.ring_max.store(samples.max(1), Ordering::SeqCst);
    }
    pub fn add_played(&self, frames: u64) {
        self.played.fetch_add(frames, Ordering::SeqCst);
    }
    pub fn played_frames(&self) -> u64 {
        self.played.load(Ordering::SeqCst)
    }
    pub fn reset_played(&self) {
        self.played.store(0, Ordering::SeqCst);
    }
    pub fn buffered(&self) -> usize {
        self.pcm.lock().unwrap().len()
    }

    /// Producer (librespot sink): append, and wait while the ring is full
    /// (backpressure) — this way librespot decodes only a little ahead and
    /// its position reports stay close to what is audible.
    pub fn feed_samples(&self, samples: &[f32]) {
        let mut off = 0;
        while off < samples.len() {
            if self.is_cancelled() {
                return;
            }
            let cap = self.ring_max.load(Ordering::SeqCst);
            let free = {
                let q = self.pcm.lock().unwrap();
                cap.saturating_sub(q.len())
            };
            if free == 0 {
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
            let n = free.min(samples.len() - off);
            let mut q = self.pcm.lock().unwrap();
            q.extend(samples[off..off + n].iter().copied());
            off += n;
        }
    }

    /// Consumer side: up to `out.len() / 2` stereo frames into `out`.
    ///
    /// Returns the number of frames (>= 0), or -1 when the stream should end
    /// (producer finished AND ring empty, or gate closed with the producer
    /// finished — then no Seeked event will ever come to open it again).
    ///
    /// Gate closed: drain the ring and deliver nothing (silence).
    /// Delivered frames count as played (add_played): the host pushes them to
    /// its BASS stream right after the call.
    pub fn read_into(&self, out: &mut [f32]) -> i64 {
        if self.is_gated() {
            self.clear_pcm();
            return if self.is_done() { -1 } else { 0 };
        }
        let want = out.len() / 2 * 2;
        let n = {
            let mut q = self.pcm.lock().unwrap();
            let n = q.len().min(want) / 2 * 2;
            for (dst, src) in out[..n].iter_mut().zip(q.drain(..n)) {
                *dst = src;
            }
            n
        };
        if n == 0 && self.is_done() {
            return -1;
        }
        let frames = (n / 2) as u64;
        if frames > 0 {
            self.add_played(frames);
        }
        frames as i64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lesen_tor_und_ende() {
        let f = PcmFeed::new_arc();
        f.set_format(2, 44100);
        f.feed_samples(&[0.1, 0.2, 0.3, 0.4, 0.5, 0.6]);
        let mut buf = [0f32; 4];
        assert_eq!(f.read_into(&mut buf), 2);
        assert_eq!(buf, [0.1, 0.2, 0.3, 0.4]);
        assert_eq!(f.played_frames(), 2);
        // Gate closed: the ring is drained, silence
        f.set_gate(true);
        assert_eq!(f.read_into(&mut buf), 0);
        assert_eq!(f.buffered(), 0);
        f.set_gate(false);
        assert_eq!(f.read_into(&mut buf), 0);
        f.mark_done();
        assert_eq!(f.read_into(&mut buf), -1);
    }
}
