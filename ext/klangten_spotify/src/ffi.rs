// Part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
// Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. See the repository's licence.

// ffi.rs — the C ABI for Klangten.
//
// Klangten is written in Ruby and loads this library through Fiddle
// (src/eapi/spotify.rb). The entry points:
//
//   ks_login()                -> status (string)
//   ks_has_login()            -> 0/1
//   ks_status()               -> status (string)
//   ks_logout()
//   ks_search(q,limit)        -> JSON [track]
//   ks_search_typed(q,limit)  -> JSON [row]
//   ks_library(limit)         -> JSON [track]
//   ks_playlists(limit)       -> JSON [{uri,name}]
//   ks_playlist_tracks(u,l)   -> JSON [track]
//   ks_track_radio(u,l)       -> JSON [track]
//   ks_show(u,l)              -> JSON {..} | null
//   ks_artist(u,l)            -> JSON {..} | null
//   ks_album(u,l)             -> JSON {..} | null
//   ks_open(u,start_ms)       -> handle (0 = none)
//   ks_stream_get(h,key)      -> string
//   ks_stream_close(h)
//   ks_read_pcm(h,buf,frames) -> frames | -1  (the host pulls the feed)
//   ks_control(a,arg)
//   ks_now_playing()          -> JSON {..}
//
// Memory rule: every function that returns `*mut c_char` returns a freshly
// allocated UTF-8 string that the caller releases with `ks_free_string`
// (never with free() — it belongs to Rust's allocator). NULL only comes back
// on an internal error (NUL byte in the text); the Ruby side treats it as
// "empty".
//
// Limits: limit <= 0 means the default for that call.
//
// Blocking: the queries wait up to QUERY_TIMEOUT for the engine thread.
// Nothing here pumps the host's event loop — the Ruby side must call them
// from a worker thread so that the user interface stays responsive.

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{json, Value};

use crate::engine::{
    self, AlbumDetails, ArtistDetails, NamedItem, NowPlaying, PlaylistInfo, SearchRow, TrackInfo,
    MAX_TRACKS,
};
use crate::feed::PcmFeed;

/// Version of the C ABI. The host checks it when loading — an older library
/// with a different signature would otherwise silently corrupt memory.
pub const ABI_VERSION: i32 = 1;

// --------------------------------------------------------------- helpers

fn s_in(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn s_out(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn json_out(v: Value) -> *mut c_char {
    s_out(v.to_string())
}

fn lim(limit: i64, default: i64, max: i64) -> usize {
    let n = if limit <= 0 { default } else { limit };
    n.clamp(1, max) as usize
}

/// Panics must never cross the C boundary (undefined behaviour; in practice
/// the host process disappears). Every entry point catches them.
fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            crate::klog!("[spotify] panic caught at the C boundary");
            fallback
        }
    }
}

fn no_pump() -> impl FnMut() {
    || {}
}

fn track_json(t: &TrackInfo) -> Value {
    json!({
        "uri": t.uri, "title": t.title, "artist": t.artist, "album": t.album,
        "duration": t.duration_ms, "artist_uri": t.artist_uri,
        "album_uri": t.album_uri,
    })
}

fn tracks_json(ts: &[TrackInfo]) -> Value {
    Value::Array(ts.iter().map(track_json).collect())
}

fn named_json(items: &[NamedItem]) -> Value {
    Value::Array(
        items
            .iter()
            .map(|n| json!({"uri": n.uri, "name": n.name}))
            .collect(),
    )
}

fn rows_json(rows: &[SearchRow]) -> Value {
    Value::Array(
        rows.iter()
            .map(|r| {
                json!({
                    "kind": r.kind, "uri": r.uri, "name": r.name, "sub": r.sub,
                    "duration": r.duration_ms, "artist_uri": r.artist_uri,
                    "album_uri": r.album_uri,
                })
            })
            .collect(),
    )
}

fn playlists_json(pls: &[PlaylistInfo]) -> Value {
    Value::Array(
        pls.iter()
            .map(|p| json!({"uri": p.uri, "name": p.name}))
            .collect(),
    )
}

fn now_json(n: &NowPlaying) -> Value {
    json!({
        "title": n.title, "artist": n.artist, "album": n.album, "uri": n.uri,
        "duration": n.duration_ms, "position": n.position_ms, "state": n.state,
    })
}

fn album_json(a: Option<AlbumDetails>) -> Value {
    match a {
        Some(a) => json!({
            "uri": a.uri, "name": a.name, "artist": a.artist,
            "tracks": tracks_json(&a.tracks),
        }),
        None => Value::Null,
    }
}

fn artist_json(a: Option<ArtistDetails>) -> Value {
    match a {
        Some(a) => json!({
            "uri": a.uri, "name": a.name, "biography": a.biography,
            "top": tracks_json(&a.top), "albums": named_json(&a.albums),
            "related": named_json(&a.related),
        }),
        None => Value::Null,
    }
}

// ---------------------------------------------------------- stream handles

/// Open streams. A handle stands for EXACTLY one feed — after a track change
/// an old handle only reads -1, like a cancelled stream.
fn streams() -> &'static Mutex<HashMap<u64, Arc<PcmFeed>>> {
    static S: OnceLock<Mutex<HashMap<u64, Arc<PcmFeed>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn stream(h: u64) -> Option<Arc<PcmFeed>> {
    streams().lock().unwrap().get(&h).cloned()
}

// ------------------------------------------------------------------ ABI

#[no_mangle]
pub extern "C" fn ks_abi_version() -> i32 {
    ABI_VERSION
}

/// Sets the cache directory (credentials, audio cache) and the log file.
/// MUST come before any other call that starts the engine; later calls
/// change nothing (OnceLock) and return 0.
#[no_mangle]
pub extern "C" fn ks_init(cache_dir: *const c_char, log_path: *const c_char) -> i32 {
    let dir = s_in(cache_dir);
    let log = s_in(log_path);
    guard(0, move || {
        if !log.is_empty() {
            crate::set_log_path(PathBuf::from(&log));
        }
        if dir.is_empty() {
            return 0;
        }
        if engine::CACHE_DIR.set(PathBuf::from(dir)).is_ok() {
            1
        } else {
            0
        }
    })
}

/// The cache directory actually in use (from ks_init, or the default).
#[no_mangle]
pub extern "C" fn ks_cache_dir() -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        s_out(engine::cache_dir().to_string_lossy().into_owned())
    })
}

#[no_mangle]
pub extern "C" fn ks_free_string(p: *mut c_char) {
    if !p.is_null() {
        unsafe {
            drop(CString::from_raw(p));
        }
    }
}

#[no_mangle]
pub extern "C" fn ks_login() -> *mut c_char {
    guard(std::ptr::null_mut(), || s_out(engine::login()))
}

#[no_mangle]
pub extern "C" fn ks_status() -> *mut c_char {
    guard(std::ptr::null_mut(), || s_out(engine::status()))
}

#[no_mangle]
pub extern "C" fn ks_has_login() -> i32 {
    guard(0, || engine::has_cached_credentials() as i32)
}

#[no_mangle]
pub extern "C" fn ks_logout() {
    guard((), engine::logout)
}

/// Hands the stored credentials (JSON from ks_credentials) to the library.
/// "" or NULL clears them. 1 = accepted, 0 = unreadable.
#[no_mangle]
pub extern "C" fn ks_set_credentials(json: *const c_char) -> i32 {
    let j = s_in(json);
    guard(0, move || engine::set_stored_credentials(&j) as i32)
}

/// The current reusable credentials as JSON ("" = none). Klangten stores
/// them itself whenever ks_credentials_serial changes.
#[no_mangle]
pub extern "C" fn ks_credentials() -> *mut c_char {
    guard(std::ptr::null_mut(), || s_out(engine::stored_credentials_json()))
}

/// Counts the library's own changes of the credentials (login, logout,
/// account without Premium).
#[no_mangle]
pub extern "C" fn ks_credentials_serial() -> i64 {
    guard(0, || engine::stored_credentials_serial() as i64)
}

/// HTML the browser shows after a successful login (translated by the host).
#[no_mangle]
pub extern "C" fn ks_set_login_page(html: *const c_char) {
    let h = s_in(html);
    guard((), move || engine::set_login_page(&h))
}

/// Ends a browser login that is still waiting for Spotify (the user gave up).
#[no_mangle]
pub extern "C" fn ks_cancel_login() {
    guard((), engine::cancel_login)
}

#[no_mangle]
pub extern "C" fn ks_search(query: *const c_char, limit: i64) -> *mut c_char {
    let q = s_in(query);
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, 30, 100);
        json_out(tracks_json(&engine::search(&q, n, &mut no_pump())))
    })
}

#[no_mangle]
pub extern "C" fn ks_search_typed(query: *const c_char, limit: i64) -> *mut c_char {
    let q = s_in(query);
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, 20, 50);
        json_out(rows_json(&engine::search_typed_pub(&q, n, &mut no_pump())))
    })
}

/// Without a limit: the WHOLE library (a former default limit of 100
/// silently cut larger collections short).
#[no_mangle]
pub extern "C" fn ks_library(limit: i64) -> *mut c_char {
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, MAX_TRACKS as i64, MAX_TRACKS as i64);
        json_out(tracks_json(&engine::library(n, &mut no_pump())))
    })
}

#[no_mangle]
pub extern "C" fn ks_playlists(limit: i64) -> *mut c_char {
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, 100, 500);
        json_out(playlists_json(&engine::playlists(n, &mut no_pump())))
    })
}

#[no_mangle]
pub extern "C" fn ks_playlist_tracks(uri: *const c_char, limit: i64) -> *mut c_char {
    let u = s_in(uri);
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, MAX_TRACKS as i64, MAX_TRACKS as i64);
        json_out(tracks_json(&engine::playlist_tracks_pub(&u, n, &mut no_pump())))
    })
}

#[no_mangle]
pub extern "C" fn ks_track_radio(uri: *const c_char, limit: i64) -> *mut c_char {
    let u = s_in(uri);
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, 50, 200);
        json_out(tracks_json(&engine::track_radio_pub(&u, n, &mut no_pump())))
    })
}

#[no_mangle]
pub extern "C" fn ks_show(uri: *const c_char, limit: i64) -> *mut c_char {
    let u = s_in(uri);
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, MAX_TRACKS as i64, MAX_TRACKS as i64);
        json_out(album_json(engine::show_pub(&u, n, &mut no_pump())))
    })
}

#[no_mangle]
pub extern "C" fn ks_artist(uri: *const c_char, limit: i64) -> *mut c_char {
    let u = s_in(uri);
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, 50, 200);
        json_out(artist_json(engine::artist_pub(&u, n, &mut no_pump())))
    })
}

#[no_mangle]
pub extern "C" fn ks_album(uri: *const c_char, limit: i64) -> *mut c_char {
    let u = s_in(uri);
    guard(std::ptr::null_mut(), move || {
        let n = lim(limit, MAX_TRACKS as i64, MAX_TRACKS as i64);
        json_out(album_json(engine::album_pub(&u, n, &mut no_pump())))
    })
}

/// Opens a track (start_ms > 0: start there — resuming an audiobook).
/// Returns a handle > 0, or 0 on failure.
#[no_mangle]
pub extern "C" fn ks_open(uri: *const c_char, start_ms: i64) -> u64 {
    let u = s_in(uri);
    guard(0, move || {
        let start = start_ms.max(0).min(u32::MAX as i64) as u32;
        match engine::open(&u, start, &mut no_pump()) {
            Some(feed) => {
                let h = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
                let mut m = streams().lock().unwrap();
                // Do not keep old, superseded streams forever: a handle whose
                // feed is cancelled and read empty can go.
                m.retain(|_, f| !(f.is_cancelled() && f.buffered() == 0));
                m.insert(h, feed);
                h
            }
            None => 0,
        }
    })
}

/// Reads stereo frames (interleaved f32, 44100 Hz) from the stream.
/// Returns the number of frames (0 = nothing available right now / seek gate
/// closed) or -1 = end of stream (or unknown handle) — the host then ends its
/// BASS stream. Called from the host's feeder thread in a tight loop: never
/// blocks, no network.
#[no_mangle]
pub extern "C" fn ks_read_pcm(handle: u64, buf: *mut f32, frames: i32) -> i32 {
    if buf.is_null() || frames <= 0 {
        return 0;
    }
    guard(-1, move || {
        let feed = match stream(handle) {
            Some(f) => f,
            None => return -1,
        };
        let out = unsafe { std::slice::from_raw_parts_mut(buf, frames as usize * 2) };
        feed.read_into(out) as i32
    })
}

/// Has the stream ended (fully decoded AND read empty)? 1 = yes.
#[no_mangle]
pub extern "C" fn ks_stream_finished(handle: u64) -> i32 {
    guard(1, move || match stream(handle) {
        Some(f) => (f.is_done() && f.buffered() == 0) as i32,
        None => 1,
    })
}

/// One property of a stream by key — state, title, artist, album, uri,
/// duration, position.
#[no_mangle]
pub extern "C" fn ks_stream_get(handle: u64, key: *const c_char) -> *mut c_char {
    let k = s_in(key);
    guard(std::ptr::null_mut(), move || {
        let now = engine::now_playing();
        let v = match k.as_str() {
            "state" => {
                // The feed state takes precedence (finished/ok); otherwise
                // the now-playing state.
                let s = stream(handle).map(|f| f.state()).unwrap_or_default();
                if s.is_empty() {
                    now.state
                } else {
                    s
                }
            }
            "title" => now.title,
            "artist" => now.artist,
            "album" => now.album,
            "uri" => now.uri,
            "duration" => now.duration_ms.to_string(),
            "position" => now.position_ms.to_string(),
            _ => String::new(),
        };
        s_out(v)
    })
}

/// Closes a stream — cancels the feed; the handle reads -1 afterwards.
#[no_mangle]
pub extern "C" fn ks_stream_close(handle: u64) {
    guard((), move || {
        if let Some(f) = streams().lock().unwrap().remove(&handle) {
            f.cancel();
            f.mark_done();
        }
    })
}

#[no_mangle]
pub extern "C" fn ks_control(action: *const c_char, arg: i64) {
    let a = s_in(action);
    guard((), move || engine::control(&a, arg))
}

#[no_mangle]
pub extern "C" fn ks_now_playing() -> *mut c_char {
    guard(std::ptr::null_mut(), || json_out(now_json(&engine::now_playing())))
}

/// Tests only: creates a stream without Spotify and fills it with `frames`
/// stereo frames (value i/1000 per sample), optionally marked as finished.
/// This lets the Ruby tests check ks_read_pcm without a login.
#[no_mangle]
pub extern "C" fn ks_test_stream(frames: i32, done: i32) -> u64 {
    guard(0, move || {
        let f = PcmFeed::new_arc();
        f.set_format(2, 44100);
        f.set_ring_max(usize::MAX / 2);
        let n = frames.max(0) as usize * 2;
        let pcm: Vec<f32> = (0..n).map(|i| i as f32 / 1000.0).collect();
        f.feed_samples(&pcm);
        f.set_state_ext("ok");
        if done != 0 {
            f.mark_done();
        }
        let h = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
        streams().lock().unwrap().insert(h, f);
        h
    })
}

/// Tests only: sets a stream's seek gate (as engine.rs does when seeking).
#[no_mangle]
pub extern "C" fn ks_test_gate(handle: u64, on: i32) {
    guard((), move || {
        if let Some(f) = stream(handle) {
            f.set_gate(on != 0);
        }
    })
}

/// Tests only: every JSON shape of the ABI with sample data, produced by the
/// SAME serialisers as the real calls — so the Ruby tests can check the
/// shapes without a Spotify login.
#[no_mangle]
pub extern "C" fn ks_test_shapes() -> *mut c_char {
    guard(std::ptr::null_mut(), || {
        let t = TrackInfo {
            uri: "spotify:track:x".into(),
            title: "Das Model".into(),
            artist: "Kraftwerk".into(),
            album: "Die Mensch-Maschine".into(),
            duration_ms: 219606,
            artist_uri: "spotify:artist:a".into(),
            album_uri: "spotify:album:b".into(),
        };
        let row = SearchRow {
            kind: "track".into(),
            uri: t.uri.clone(),
            name: t.title.clone(),
            sub: t.artist.clone(),
            duration_ms: t.duration_ms,
            artist_uri: t.artist_uri.clone(),
            album_uri: t.album_uri.clone(),
        };
        let named = NamedItem { uri: "spotify:album:b".into(), name: "Die Mensch-Maschine".into() };
        let album = AlbumDetails {
            uri: "spotify:album:b".into(),
            name: "Die Mensch-Maschine".into(),
            artist: "Kraftwerk".into(),
            tracks: vec![t.clone()],
        };
        let artist = ArtistDetails {
            uri: "spotify:artist:a".into(),
            name: "Kraftwerk".into(),
            biography: "<a href=\"x\">Kraftwerk</a> aus Düsseldorf".into(),
            top: vec![t.clone()],
            albums: vec![named.clone()],
            related: vec![NamedItem { uri: "spotify:artist:c".into(), name: "Neu!".into() }],
        };
        let pl = PlaylistInfo { uri: "spotify:playlist:p".into(), name: "Lieblinge".into() };
        let now = NowPlaying {
            uri: t.uri.clone(),
            title: t.title.clone(),
            artist: t.artist.clone(),
            album: t.album.clone(),
            duration_ms: t.duration_ms,
            position_ms: 1000,
            state: "playing".into(),
        };
        json_out(json!({
            "tracks": tracks_json(&[t]),
            "rows": rows_json(&[row]),
            "playlists": playlists_json(&[pl]),
            "album": album_json(Some(album)),
            "artist": artist_json(Some(artist)),
            "none": album_json(None),
            "now": now_json(&now),
        }))
    })
}
