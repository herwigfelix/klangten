// feed.rs — der PCM-Ringpuffer zwischen librespot und dem Klango-4-Mischer.
//
// Gegenstück zu Klango 3s IcyFeed (klango_rs/src/engine/icy.rs), soweit
// Spotify es braucht: Push/Drain-Ring mit Backpressure, Format, done/cancel,
// Spul-Tor (gate) und Abspielzähler (played). Zwei Unterschiede:
//
//   * f32 statt i16 — der Klango-4-Mischer (lucia/miniaudio) rechnet in
//     float32, eine Rundreise über i16 brächte nur Quantisierung;
//   * die Mischer-Seite (Tor beachten, Ring leeren, gespielte Frames melden)
//     steckt hier in `read_into`, weil Klango 4 seinen Mischer in Python hat:
//     ks_read_pcm (ffi.rs) ruft genau diese Funktion aus dem Audio-Callback.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Ringpuffer-Deckel als Vorgabe (~10 s Stereo @44,1 kHz) — Spotify setzt
/// ihn beim Öffnen kleiner (open_track: ~2 s).
const RING_MAX: usize = 44100 * 2 * 10;

pub struct PcmFeed {
    state: Mutex<String>,
    /// dekodiertes, interleaved PCM (Stereo)
    pcm: Mutex<VecDeque<f32>>,
    fmt: Mutex<Option<(u32, u32)>>,
    cancel: AtomicBool,
    /// Produzent fertig (Titelende). Der Mischer beendet die Instanz, sobald
    /// der Puffer leer ist.
    done: AtomicBool,
    /// Spul-Tor: solange gesetzt, verwirft die Mischer-Seite allen Nachschub
    /// (kurze Stille), statt librespots noch aus der Voraus-Dekodierung
    /// stammendes Alt-Audio zu spielen (ein Rückwärts-Sprung klänge sonst
    /// nach vorn). Begründung ausführlich in Klango 3, icy.rs:`gate`.
    gate: AtomicBool,
    ring_max: AtomicUsize,
    /// Vom Mischer GESPIELTE Frames seit Titelstart bzw. letztem Seek —
    /// daraus rechnet engine.rs die HÖRBARE Position.
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
    /// Gepuffertes PCM verwerfen — beim Spulen, damit librespot nicht per
    /// Backpressure blockiert und ab der neuen Stelle nachliefern kann.
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

    /// Produzent (librespot-Sink): anhängen, bei vollem Ring warten
    /// (Backpressure) — so dekodiert librespot nur wenig voraus und seine
    /// Positionsmeldungen bleiben dicht am Hörbaren.
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

    /// Mischer-Seite: bis zu `out.len() / 2` Stereo-Frames nach `out`.
    ///
    /// Rückgabe: Anzahl Frames (>= 0) oder -1, wenn die Instanz enden soll
    /// (Produzent fertig UND Ring leer, bzw. Tor zu bei fertigem Produzenten
    /// — dann kommt nie mehr ein Seeked, das es öffnen könnte; Klango 3
    /// mixer.rs beendet die Instanz in genau diesen beiden Fällen).
    ///
    /// Tor zu: Ring leeren, nichts liefern (Stille) — wie mixer.rs.
    /// Gelieferte Frames zählen als gespielt (add_played): der Python-
    /// Mischer verbraucht sie im selben Callback.
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
        // Tor zu: Ring wird geleert, Stille
        f.set_gate(true);
        assert_eq!(f.read_into(&mut buf), 0);
        assert_eq!(f.buffered(), 0);
        f.set_gate(false);
        assert_eq!(f.read_into(&mut buf), 0);
        f.mark_done();
        assert_eq!(f.read_into(&mut buf), -1);
    }
}
