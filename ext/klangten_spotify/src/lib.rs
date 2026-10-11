// klango_spotify — Spotify für Klango 4 als native Bibliothek (cdylib).
//
//   engine.rs  die Engine, 1:1 aus Klango 3 (klango_rs/src/engine/spotify.rs)
//   feed.rs    PCM-Ringpuffer (f32) zwischen librespot und Klangos Mischer
//   ffi.rs     die C-ABI, die klango4/src/klango4/engine/spotify.py lädt
//
// Bauen: native/spotify/build.sh (macOS) bzw. build_win.cmd (Windows);
// beide legen das Ergebnis nach klango4/vendor/spotify_<os>/.

pub mod engine;
pub mod feed;
pub mod ffi;

use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

static LOG_PATH: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

fn log_slot() -> &'static Mutex<Option<PathBuf>> {
    LOG_PATH.get_or_init(|| Mutex::new(None))
}

/// Logdatei festlegen (Klango 4: ~/.klango4/klango4.log). Ohne Angabe geht
/// das Protokoll nach stderr — nur, wenn KLANGO_DEBUG gesetzt ist.
pub fn set_log_path(p: PathBuf) {
    *log_slot().lock().unwrap() = Some(p);
}

#[doc(hidden)]
pub fn log_line(s: &str) {
    let path = log_slot().lock().unwrap().clone();
    match path {
        Some(p) => {
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(p) {
                let _ = writeln!(f, "{}", s);
            }
        }
        None => {
            if std::env::var_os("KLANGO_DEBUG").is_some() {
                eprintln!("{}", s);
            }
        }
    }
    if std::env::var_os("KLANGO_DEBUG").is_some() && log_slot().lock().unwrap().is_some() {
        eprintln!("{}", s);
    }
}

/// Gegenstück zu Klango 3s hlog!: eine Zeile ins Host-Protokoll.
#[macro_export]
macro_rules! klog {
    ($($arg:tt)*) => {
        $crate::log_line(&format!($($arg)*))
    };
}
