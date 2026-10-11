// Part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
// Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. See the repository's licence.

// klangten_spotify — Spotify playback for Klangten as a native library (cdylib).
//
//   engine.rs  the engine: login, Spotify Web/metadata queries, playback
//   feed.rs    PCM ring buffer (f32) between librespot and the host's audio output
//   ffi.rs     the C ABI that src/eapi/spotify.rb loads through Fiddle
//
// Build: tools/build-spotify.sh (macOS, Linux) or tools\build-spotify.bat
// (Windows); both place the library in bin/<runtime>/.

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

/// Sets the log file (passed in by the host through ks_init). Without one the
/// log goes to stderr — but only if KLANGTEN_SPOTIFY_DEBUG is set.
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
            if std::env::var_os("KLANGTEN_SPOTIFY_DEBUG").is_some() {
                eprintln!("{}", s);
            }
        }
    }
    if std::env::var_os("KLANGTEN_SPOTIFY_DEBUG").is_some() && log_slot().lock().unwrap().is_some() {
        eprintln!("{}", s);
    }
}

/// Writes one line to the log (see log_line).
#[macro_export]
macro_rules! klog {
    ($($arg:tt)*) => {
        $crate::log_line(&format!($($arg)*))
    };
}
