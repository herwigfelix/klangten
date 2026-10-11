// ffi.rs — die C-ABI für Klango 4 (an Stelle der k_Spotify*-Globals).
//
// Klango 3 registrierte die Engine als Lua-Globals (spotify.rs: register).
// Klango 4 ist Python und lädt diese Bibliothek per ctypes
// (src/klango4/engine/spotify.py). Die Abbildung ist eins zu eins:
//
//   k_SpotifyLogin()            ks_login()                -> Status (String)
//   k_SpotifyHasLogin()         ks_has_login()            -> 0/1
//   k_SpotifyStatus()           ks_status()               -> Status (String)
//   k_SpotifyLogout()           ks_logout()
//   k_SpotifySearch(q,limit)    ks_search(q,limit)        -> JSON [Titel]
//   k_SpotifySearch2(q,limit)   ks_search_typed(q,limit)  -> JSON [Zeile]
//   k_SpotifyLibrary(limit)     ks_library(limit)         -> JSON [Titel]
//   k_SpotifyPlaylists(limit)   ks_playlists(limit)       -> JSON [{uri,name}]
//   k_SpotifyPlaylistTracks     ks_playlist_tracks(u,l)   -> JSON [Titel]
//   k_SpotifyTrackRadio         ks_track_radio(u,l)       -> JSON [Titel]
//   k_SpotifyShow(uri,limit)    ks_show(u,l)              -> JSON {..} | null
//   k_SpotifyArtist(uri,limit)  ks_artist(u,l)            -> JSON {..} | null
//   k_SpotifyAlbum(uri,limit)   ks_album(u,l)             -> JSON {..} | null
//   k_SpotifyOpen(uri,start)    ks_open(u,start_ms)       -> Handle (0 = nil)
//   stream:Get(key)             ks_stream_get(h,key)      -> String
//   stream:Close()              ks_stream_close(h)
//   (Mixer zieht den Feed)      ks_read_pcm(h,buf,frames) -> Frames | -1
//   k_SpotifyControl(a,arg)     ks_control(a,arg)
//   k_SpotifyNowPlaying()       ks_now_playing()          -> JSON {..}
//
// Speicherregel: Jede Funktion, die `*mut c_char` liefert, gibt einen frisch
// angelegten UTF-8-String zurück, den der Aufrufer mit `ks_free_string`
// freigibt (nie mit free() — Rusts Allocator). NULL kommt nur bei innerem
// Fehler (NUL-Byte im Text); Python behandelt es wie "leer".
//
// Grenzen (limit <= 0 = Vorgabe) und Vorgaben wie in register() von Klango 3.
//
// Blockieren: die Abfragen warten wie in Klango 3 bis QUERY_TIMEOUT auf den
// Engine-Thread. Den Frame pumpt hier NIEMAND — die Python-Seite ruft sie in
// einem Arbeits-Thread und pumpt derweil Klangos Schleife (ctypes gibt den
// GIL für die Dauer des Aufrufs frei).

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

/// Version der C-ABI. Python prüft sie beim Laden — eine ältere Bibliothek
/// mit anderer Signatur würde sonst still Speicher zerschreiben.
pub const ABI_VERSION: i32 = 1;

// ---------------------------------------------------------------- Helfer

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

/// Panics dürfen nie über die C-Grenze laufen (undefiniertes Verhalten,
/// in der Praxis: Klango verschwindet). Jeder Einstieg fängt sie ab.
fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            crate::klog!("[spotify] Panic an der C-Grenze abgefangen");
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

// ------------------------------------------------------------ Strom-Handles

/// Offene Ströme (Klango 3: SpotifyStream-Userdata). Ein Handle steht für
/// GENAU einen Feed — nach einem Titelwechsel liest ein altes Handle nur
/// noch -1, wie eine abgebrochene Instanz in Klango 3.
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

/// Zwischenspeicher (Anmeldedaten, Audio-Cache) und Logdatei festlegen.
/// MUSS vor jedem anderen Aufruf kommen, der die Engine startet; spätere
/// Aufrufe ändern nichts mehr (OnceLock) und liefern 0.
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

/// Der tatsächlich benutzte Zwischenspeicher (nach ks_init bzw. Vorgabe).
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

/// Ohne Angabe: die GANZE Mediathek (Klango 3: altes Standardlimit 100
/// schnitt größere Sammlungen stumm ab).
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

/// Titel öffnen (start_ms > 0: dort einsetzen — Hörbuch fortsetzen).
/// Rückgabe: Handle > 0, oder 0 wie `nil` in Klango 3.
#[no_mangle]
pub extern "C" fn ks_open(uri: *const c_char, start_ms: i64) -> u64 {
    let u = s_in(uri);
    guard(0, move || {
        let start = start_ms.max(0).min(u32::MAX as i64) as u32;
        match engine::open(&u, start, &mut no_pump()) {
            Some(feed) => {
                let h = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
                let mut m = streams().lock().unwrap();
                // Alte, abgelöste Ströme nicht ewig halten: ein Handle, dessen
                // Feed abgebrochen und leergelesen ist, kann weg.
                m.retain(|_, f| !(f.is_cancelled() && f.buffered() == 0));
                m.insert(h, feed);
                h
            }
            None => 0,
        }
    })
}

/// Stereo-Frames (interleaved f32, 44100 Hz) aus dem Strom lesen.
/// Rückgabe: Anzahl Frames (0 = gerade nichts da / Spul-Tor zu) oder -1 =
/// Strom zu Ende (bzw. unbekanntes Handle) — der Mischer beendet dann die
/// Instanz. Aus dem Audio-Callback gerufen: kein Blockieren, kein Netz.
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

/// Strom zu Ende (fertig dekodiert UND leergelesen)? 1 = ja.
#[no_mangle]
pub extern "C" fn ks_stream_finished(handle: u64) -> i32 {
    guard(1, move || match stream(handle) {
        Some(f) => (f.is_done() && f.buffered() == 0) as i32,
        None => 1,
    })
}

/// Gegenstück zu SpotifyStream:Get(key) — state, title, artist, album, uri,
/// duration, position.
#[no_mangle]
pub extern "C" fn ks_stream_get(handle: u64, key: *const c_char) -> *mut c_char {
    let k = s_in(key);
    guard(std::ptr::null_mut(), move || {
        let now = engine::now_playing();
        let v = match k.as_str() {
            "state" => {
                // Feed-Zustand hat Vorrang (finished/ok); sonst Now-State.
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

/// SpotifyStream:Close() — Feed abbrechen; das Handle liest danach -1.
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

/// Nur für Tests: einen Strom ohne Spotify anlegen und mit `frames`
/// Stereo-Frames füllen (Wert i/1000 je Sample), optional als fertig
/// markiert. So lässt sich ks_read_pcm von Python aus prüfen, ohne Login.
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

/// Nur für Tests: Spul-Tor eines Stroms setzen (wie engine.rs beim Spulen).
#[no_mangle]
pub extern "C" fn ks_test_gate(handle: u64, on: i32) {
    guard((), move || {
        if let Some(f) = stream(handle) {
            f.set_gate(on != 0);
        }
    })
}

/// Nur für Tests: alle JSON-Formen der ABI mit Beispieldaten, erzeugt von
/// DENSELBEN Serialisierern wie die echten Aufrufe — so prüft Python die
/// Formen ohne Spotify-Anmeldung.
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
