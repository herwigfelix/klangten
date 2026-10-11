// Part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
// Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3. See the repository's licence.

// engine.rs — Spotify playback through librespot (native Rust client) for
// Klangten: session + player on their own tokio thread, browser OAuth
// fire-and-forget with status polling, credential cache, recovery after
// network errors (resume_point/retire/trouble), search, song radio,
// audiobook/artist/album/playlist/library, open(uri,start_ms),
// control(action,arg), now_playing.
//
//   * The host talks to the engine through a C ABI (src/ffi.rs), which
//     Klangten loads through Fiddle (src/eapi/spotify.rb).
//   * The sink writes into a ring buffer of its own (src/feed.rs, f32), from
//     which a Ruby thread pulls with ks_read_pcm and feeds a BASS push stream.
//
// librespot handles login (OAuth), search, the user's library and playlists
// with ONE login (spclient, no separate Web API token) and decodes
// Ogg/Vorbis to PCM. A sink of our own pushes that PCM into the feed.
//
// Concurrency: librespot is async. ONE tokio runtime runs on its own OS
// thread and owns session + player. The ABI calls send commands over a
// channel; short queries (search/library) wait synchronously for the answer.
// Login, on the other hand, is fire-and-forget (browser OAuth can take a long
// time); the host polls ks_status. The shared state (login/now playing) lives
// in Arc<Mutex> and is read directly, without going through the channel.
//
// Premium: librespot streams ONLY with Spotify Premium. Login also succeeds
// with free accounts, but playback then fails (PlayerEvent::Unavailable) →
// state "unavailable", and the host tells the user Premium is required.

#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::error::ErrorKind;
use librespot_core::session::Session;
use librespot_core::spotify_uri::SpotifyUri;
use librespot_metadata::{Metadata, Track};
use librespot_playback::audio_backend::{Open, Sink, SinkError, SinkResult};
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::mixer::{NoOpVolume, VolumeGetter};
use librespot_playback::player::{Player, PlayerEvent, PlayerEventChannel};

use crate::feed::PcmFeed;

// The librespot client ID (the same one librespot uses internally).
const SPOTIFY_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const OAUTH_REDIRECT: &str = "http://127.0.0.1:5588/login";
const OAUTH_SCOPES: &[&str] = &[
    "streaming",
    "user-read-playback-state",
    "user-read-currently-playing",
    "playlist-read-private",
    "user-library-read",
];

/// Spotify delivers 44100 Hz stereo; the sink passes the f64 samples on as
/// interleaved f32 (BASS plays float samples, also at 44100 Hz).
const SR: u32 = 44100;
const CH: u32 = 2;

/// Cache directory — set by the host through ks_init (ffi.rs).
pub static CACHE_DIR: OnceLock<PathBuf> = OnceLock::new();

// ---- Connection time limits (see "Connection: establish, check,
// re-establish" further down) ----

/// Upper limit for a single network request (context, metadata, search,
/// token). librespot's HTTP client has NO time limit: a request over a
/// half-dead connection (sleep, expired NAT entry) hung until the system's
/// TCP timeout, i.e. minutes. Because the engine thread processes commands one
/// after another, EVERY further Spotify request hung with it — that was
/// "after a long idle period the search times out and the connection never
/// comes back".
const REQ_TIMEOUT: Duration = Duration::from_secs(8);
/// Establishing the connection (find an access point, connect, log in).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// If no packet arrived from the access point for this long (wall clock), the
/// connection counts as dead: the server sends a ping or PongAck at least
/// every 60 s.
const STALE_AFTER_MS: u64 = 100_000;
/// Browser login: after this the engine thread gives up instead of waiting
/// forever (while it waits, every other Spotify command stays queued).
const OAUTH_TIMEOUT: Duration = Duration::from_secs(300);

// ---------------------------------------------------------------------------
// Shared state (the ABI reads it directly, without a command)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub enum LoginState {
    LoggedOut,
    LoggingIn,
    LoggedIn,
    /// Login succeeded, but the account has no Premium. A state of its OWN,
    /// not Failed: the user did nothing wrong, and the host must tell them
    /// something other than "login failed".
    NoPremium,
    Failed(String),
}

impl LoginState {
    fn as_str(&self) -> &str {
        match self {
            LoginState::LoggedOut => "loggedout",
            LoginState::LoggingIn => "loggingin",
            LoginState::LoggedIn => "ok",
            LoginState::NoPremium => "nopremium",
            LoginState::Failed(_) => "failed",
        }
    }
}

#[derive(Clone, Default, Debug)]
pub struct NowPlaying {
    pub uri: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    pub position_ms: u32,
    pub state: String, // loading | playing | paused | finished | unavailable | stopped
}

struct Shared {
    login: Mutex<LoginState>,
    now: Mutex<NowPlaying>,
    /// Target feed of the sink — replaced when a new track is opened.
    current_feed: Mutex<Option<Arc<PcmFeed>>>,
    /// Seek in progress: target position in ms. While set, a seek is "in
    /// progress". librespot still reports the OLD position for a short while
    /// afterwards (events lag behind asynchronously) — that would corrupt the
    /// base for relative seeking (seeking back would then jump forward) and a
    /// seek EndOfTrack would wrongly advance the track. While seek_target is
    /// set we ignore late position/end events until an event confirms the
    /// target position (then the seek counts as done).
    seek_target: Mutex<Option<u32>>,
    /// Base of the AUDIBLE position: position at track start (0) or at the
    /// last confirmed seek. Audible = base + frames played by the consumer
    /// since then (feed.played_frames). librespot's event position, by
    /// contrast, is the DECODE position, which runs ahead of what is audible
    /// by the buffer lead — as a seek base it would be wrong (seeking back
    /// would then jump forward).
    audible_base_ms: Mutex<u32>,
}

impl Shared {
    fn set_login(&self, s: LoginState) {
        *self.login.lock().unwrap() = s;
    }
    fn set_state(&self, s: &str) {
        self.now.lock().unwrap().state = s.to_string();
    }
}

/// A track for result lists (search/library/playlist).
#[derive(Clone, Debug)]
pub struct TrackInfo {
    pub uri: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    /// URIs of the track's artist and album. librespot can ONLY search for
    /// tracks (all other search kinds are not available through spclient,
    /// checked 2026-08-28). Artists and albums are therefore derived from the
    /// track hits — which is why the host needs these two identifiers.
    pub artist_uri: String,
    pub album_uri: String,
}

/// Name + URI — for albums, artists and related artists.
#[derive(Clone, Debug, Default)]
pub struct NamedItem {
    pub uri: String,
    pub name: String,
}

/// An artist page: everything the host shows for an artist.
#[derive(Clone, Debug, Default)]
pub struct ArtistDetails {
    pub uri: String,
    pub name: String,
    pub biography: String,
    pub top: Vec<TrackInfo>,
    pub albums: Vec<NamedItem>,
    pub related: Vec<NamedItem>,
}

/// An album with its tracks.
#[derive(Clone, Debug, Default)]
pub struct AlbumDetails {
    pub uri: String,
    pub name: String,
    pub artist: String,
    pub tracks: Vec<TrackInfo>,
}

/// One of the user's playlists.
#[derive(Clone, Debug)]
pub struct PlaylistInfo {
    pub uri: String,
    pub name: String,
}

// ---------------------------------------------------------------------------
// Commands to the engine thread
// ---------------------------------------------------------------------------

enum Cmd {
    /// Log in (fire-and-forget; the host polls the login state).
    Login,
    Logout,
    Search {
        query: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<TrackInfo>>,
    },
    Library {
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<TrackInfo>>,
    },
    Playlists {
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<PlaylistInfo>>,
    },
    PlaylistTracks {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<TrackInfo>>,
    },
    /// Recommendations for a track ("song radio").
    TrackRadio {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<TrackInfo>>,
    },
    /// Typed search (tracks, artists, albums, playlists, audiobooks,
    /// podcasts) through pathfinder.
    SearchTyped {
        query: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<SearchRow>>,
    },
    /// Audiobook/podcast with its chapters or episodes.
    Show {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Option<AlbumDetails>>,
    },
    /// Artist page (top tracks, albums, related artists, biography).
    Artist {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Option<ArtistDetails>>,
    },
    /// Album with its tracks.
    Album {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Option<AlbumDetails>>,
    },
    /// Open a track: create a new feed, load, return the feed.
    /// `start_ms` > 0 starts there — so an audiobook continues where it was
    /// left.
    Open {
        uri: String,
        start_ms: u32,
        reply: std::sync::mpsc::Sender<Option<Arc<PcmFeed>>>,
    },
    Control {
        action: String,
        arg: i64,
    },
}

// ---------------------------------------------------------------------------
// librespot sink → PCM feed
// ---------------------------------------------------------------------------

/// Pushes librespot's decoded PCM into the current feed. The feed is
/// replaced when a new track is opened (Arc<Mutex<Option<…>>>); the sink
/// stays the same (the player is only built once).
struct FeedSink {
    slot: Arc<Mutex<Option<Arc<PcmFeed>>>>,
}

impl Open for FeedSink {
    fn open(_device: Option<String>, _format: AudioFormat) -> Self {
        // Never called — the player builds the sink through the closure with
        // the real slot. Fallback: empty slot (write then silently discards).
        FeedSink {
            slot: Arc::new(Mutex::new(None)),
        }
    }
}

impl Sink for FeedSink {
    fn start(&mut self) -> SinkResult<()> {
        Ok(())
    }
    fn stop(&mut self) -> SinkResult<()> {
        Ok(())
    }
    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        match packet {
            AudioPacket::Samples(samples) => {
                // No conversion to i16: the host plays float samples, so
                // the samples go through as f32. The player has already
                // applied normalisation.
                let _ = &converter;
                let pcm: Vec<f32> = samples.iter().map(|&x| x as f32).collect();
                // Only push into the CURRENT feed; after a switch the old
                // feed is cancelled and ignored.
                let feed = {
                    let g = self.slot.lock().unwrap();
                    g.clone()
                };
                if let Some(feed) = feed {
                    if !feed.is_cancelled() {
                        feed.feed_samples(&pcm);
                    }
                }
                Ok(())
            }
            AudioPacket::Raw(_) => Err(SinkError::OnWrite(
                "raw passthrough is not supported".into(),
            )),
        }
    }
}

// ---------------------------------------------------------------------------
// Engine (global singleton)
// ---------------------------------------------------------------------------

pub struct SpotifyEngine {
    tx: tokio::sync::mpsc::UnboundedSender<Cmd>,
    shared: Arc<Shared>,
}

static ENGINE: OnceLock<SpotifyEngine> = OnceLock::new();

fn engine() -> &'static SpotifyEngine {
    ENGINE.get_or_init(start_engine)
}

pub fn cache_dir() -> PathBuf {
    CACHE_DIR
        .get()
        .cloned()
        .unwrap_or_else(|| std::env::temp_dir().join("klangten_spotify_cache"))
}

fn start_engine() -> SpotifyEngine {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<Cmd>();
    let shared = Arc::new(Shared {
        login: Mutex::new(LoginState::LoggedOut),
        now: Mutex::new(NowPlaying::default()),
        current_feed: Mutex::new(None),
        seek_target: Mutex::new(None),
        audible_base_ms: Mutex::new(0),
    });
    let shared_thread = shared.clone();
    std::thread::Builder::new()
        .name("klangten-spotify".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(r) => r,
                Err(e) => {
                    crate::klog!("[spotify] tokio runtime failed: {}", e);
                    shared_thread.set_login(LoginState::Failed("runtime".into()));
                    return;
                }
            };
            rt.block_on(engine_loop(rx, shared_thread));
        })
        .expect("spotify-thread");
    SpotifyEngine { tx, shared }
}

/// Player events run in a task of their OWN (not in the select of the command
/// loop) — that cleanly decouples them and avoids double &mut borrows of
/// `events`. The task ends when the player goes away (channel closes).
fn spawn_event_task(mut ch: PlayerEventChannel, shared: Arc<Shared>) {
    tokio::spawn(async move {
        while let Some(ev) = ch.recv().await {
            handle_event(ev, &shared);
        }
    });
}

async fn engine_loop(mut rx: tokio::sync::mpsc::UnboundedReceiver<Cmd>, shared: Arc<Shared>) {
    let mut conn = Conn::default();

    while let Some(cmd) = rx.recv().await {
        handle_cmd(cmd, &mut conn, &shared).await;
    }
}

/// Does this event belong to the track that is loaded RIGHT NOW? When
/// switching, librespot still fires Stopped/EndOfTrack for the OLD track — if
/// that were applied blindly to shared.current_feed (already the NEW feed!),
/// the new track would immediately count as "finished" and the player would
/// skip on endlessly. Hence every end/error event is tied to the track URI.
fn is_current(track_id: &SpotifyUri, shared: &Arc<Shared>) -> bool {
    match track_id.to_uri() {
        Ok(u) => u == shared.now.lock().unwrap().uri,
        Err(_) => false,
    }
}

/// Completes a seek: clear the target, open the seek gate (the consumer plays
/// the feed again instead of silence) and adopt the real position.
fn finish_seek(shared: &Arc<Shared>, position_ms: u32) {
    *shared.seek_target.lock().unwrap() = None;
    // New audible base: from here on the consumer counts played frames again.
    // Reset the counter BEFORE opening the gate, otherwise stale frames count.
    *shared.audible_base_ms.lock().unwrap() = position_ms;
    if let Some(feed) = shared.current_feed.lock().unwrap().as_ref() {
        feed.reset_played();
        feed.set_gate(false);
    }
    shared.now.lock().unwrap().position_ms = position_ms;
}

/// AUDIBLE position: base (track start/last seek) + frames played by the
/// consumer since then. Fallback (no feed/format): librespot's event position.
fn audible_position_ms(shared: &Arc<Shared>) -> u32 {
    let base = *shared.audible_base_ms.lock().unwrap();
    let feed = shared.current_feed.lock().unwrap().clone();
    if let Some(f) = feed {
        if let Some((_, sr)) = f.format() {
            if sr > 0 {
                return base.saturating_add((f.played_frames() * 1000 / sr as u64) as u32);
            }
        }
    }
    shared.now.lock().unwrap().position_ms
}

/// Adopts the position from a librespot event — but while a seek is in
/// progress, ignore the OLD position still reported late, until an event
/// confirms the target position (± tolerance) (fallback in case the Seeked
/// event never comes). Then the seek counts as done.
fn apply_position(shared: &Arc<Shared>, position_ms: u32) {
    const SEEK_SETTLE_MS: u32 = 3000;
    enum A {
        Settle,
        Ignore,
        Update,
    }
    let action = {
        let tgt = shared.seek_target.lock().unwrap();
        match *tgt {
            Some(t) if position_ms.abs_diff(t) <= SEEK_SETTLE_MS => A::Settle,
            Some(_) => A::Ignore,
            None => A::Update,
        }
    };
    match action {
        A::Settle => finish_seek(shared, position_ms),
        A::Update => shared.now.lock().unwrap().position_ms = position_ms,
        A::Ignore => {}
    }
}

fn seeking(shared: &Arc<Shared>) -> bool {
    shared.seek_target.lock().unwrap().is_some()
}

fn handle_event(ev: PlayerEvent, shared: &Arc<Shared>) {
    match ev {
        PlayerEvent::Playing { position_ms, track_id, .. } => {
            if is_current(&track_id, shared) {
                apply_position(shared, position_ms);
                shared.now.lock().unwrap().state = "playing".into();
            }
        }
        PlayerEvent::Paused { position_ms, track_id, .. } => {
            if is_current(&track_id, shared) {
                apply_position(shared, position_ms);
                shared.now.lock().unwrap().state = "paused".into();
            }
        }
        PlayerEvent::Seeked { position_ms, track_id, .. } => {
            // Authoritative end of seek: open the gate, adopt the real position.
            if is_current(&track_id, shared) {
                finish_seek(shared, position_ms);
            }
        }
        PlayerEvent::PositionChanged { position_ms, track_id, .. } => {
            if is_current(&track_id, shared) {
                apply_position(shared, position_ms);
            }
        }
        PlayerEvent::EndOfTrack { track_id, .. } => {
            // ONLY the end of the current track — not the stop echo of a
            // previous track (is_current). If a seek was still running, the
            // end of track overtook it: the player has already stopped, and a
            // Seeked will never come — complete the seek, otherwise the seek
            // gate stays closed forever (endless silence instead of the next
            // track).
            if is_current(&track_id, shared) {
                if seeking(shared) {
                    let d = shared.now.lock().unwrap().duration_ms;
                    finish_seek(shared, d);
                }
                if let Some(feed) = shared.current_feed.lock().unwrap().as_ref() {
                    feed.mark_done();
                    feed.set_state_ext("finished");
                }
                shared.set_state("finished");
            }
        }
        PlayerEvent::Unavailable { track_id, .. } => {
            // Track not playable — most common reason: no Premium.
            if is_current(&track_id, shared) && !seeking(shared) {
                if let Some(feed) = shared.current_feed.lock().unwrap().as_ref() {
                    feed.set_state_ext("unavailable");
                    feed.cancel();
                    feed.mark_done();
                }
                shared.set_state("unavailable");
            }
        }
        // Stopped fires on switching/loading (for the OLD track) — on an
        // explicit stop the feed is cleaned up by control() anyway. Ignored
        // deliberately here, otherwise the new track would count as stopped
        // at once.
        _ => {}
    }
}

async fn handle_cmd(cmd: Cmd, conn: &mut Conn, shared: &Arc<Shared>) {
    match cmd {
        Cmd::Login => {
            if conn.alive() && matches!(*shared.login.lock().unwrap(), LoginState::LoggedIn) {
                return;
            }
            shared.set_login(LoginState::LoggingIn);
            reset_trouble();
            // Explicit login: only HERE may a browser open.
            match reconnect(conn, shared, true, Resume::Keep).await {
                Ok(()) => {}
                Err(e) if e == NO_PREMIUM => {
                    crate::klog!("[spotify] account without Premium — no playback.");
                }
                Err(e) => {
                    crate::klog!("[spotify] login failed: {}", e);
                    shared.set_login(LoginState::Failed(e));
                }
            }
        }
        Cmd::Logout => {
            retire(conn);
            *shared.current_feed.lock().unwrap() = None;
            *shared.now.lock().unwrap() = NowPlaying::default();
            shared.set_login(LoginState::LoggedOut);
            // Clear the stored credentials so that the next login really
            // signs in anew.
            forget_credentials();
        }
        Cmd::Search { query, limit, reply } => {
            let out = run_query(conn, shared, "Search", |s: Session| {
                let q = &query;
                async move { search_tracks(&s, q, limit).await }
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::Library { limit, reply } => {
            let out = run_query(conn, shared, "Library", |s: Session| async move {
                liked_tracks(&s, limit).await
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::Playlists { limit, reply } => {
            let out = run_query(conn, shared, "Playlists", |s: Session| async move {
                user_playlists(&s, limit).await
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::PlaylistTracks { uri, limit, reply } => {
            let out = run_query(conn, shared, "Playlist tracks", |s: Session| {
                let u = &uri;
                async move { playlist_tracks(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::TrackRadio { uri, limit, reply } => {
            let out = run_query(conn, shared, "Song radio", |s: Session| {
                let u = &uri;
                async move { track_radio(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::SearchTyped { query, limit, reply } => {
            let out = run_query(conn, shared, "Search", |s: Session| {
                let q = &query;
                async move {
                    match search_typed(&s, q, limit).await {
                        Some(rows) => Some(rows),
                        // pathfinder not reachable (query hash outdated?):
                        // at least deliver the tracks through the context route.
                        None => search_tracks(&s, q, limit).await.map(|v| {
                            v.into_iter()
                                .map(|t| SearchRow {
                                    kind: "track".into(),
                                    uri: t.uri,
                                    name: t.title,
                                    sub: t.artist,
                                    duration_ms: t.duration_ms,
                                    artist_uri: t.artist_uri,
                                    album_uri: t.album_uri,
                                })
                                .collect()
                        }),
                    }
                }
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::Show { uri, limit, reply } => {
            let out = run_query(conn, shared, "Audiobook/podcast", |s: Session| {
                let u = &uri;
                async move { show_details(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out);
        }
        Cmd::Artist { uri, limit, reply } => {
            let out = run_query(conn, shared, "Artist", |s: Session| {
                let u = &uri;
                async move { artist_details(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out);
        }
        Cmd::Album { uri, limit, reply } => {
            let out = run_query(conn, shared, "Album", |s: Session| {
                let u = &uri;
                async move { album_details(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out);
        }
        Cmd::Open { uri, start_ms, reply } => {
            reset_trouble();
            // The old track is replaced anyway — resume nothing.
            if let Err(e) = ensure_live(conn, shared, Resume::Drop).await {
                crate::klog!("[spotify] opening track: {}", e);
            }
            let feed = open_track(&conn.session, &conn.player, shared, &uri, start_ms).await;
            let _ = reply.send(feed);
        }
        Cmd::Control { action, arg } => {
            if action == "stop" {
                if let Some(p) = conn.player.as_ref() {
                    p.stop();
                }
                if let Some(feed) = shared.current_feed.lock().unwrap().as_ref() {
                    feed.cancel();
                    feed.mark_done();
                }
                return;
            }
            if action == "seekrel" {
                // Relative seeking (left/right arrow in the host's player):
                // arg = offset in ms (±). The PCM feed itself cannot seek
                // (it is a live stream) — so the engine computes a new
                // absolute position from the current one and lets librespot
                // jump there.
                //
                // Track already fully decoded (librespot stopped
                // internally)? Then p.seek would be a no-op — no Seeked
                // would ever come, the gate would stay closed and the track
                // would hang in endless silence. Silently ignore seeking in
                // the remaining tail; the natural end (next track) is near.
                let feed_done = shared
                    .current_feed
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|f| f.is_done())
                    .unwrap_or(true);
                if feed_done || conn.player.is_none() {
                    return;
                }
                // The base is the running seek target (if a seek is in
                // progress), otherwise the AUDIBLE position — librespot's
                // event position is the decode position and runs ahead of
                // the ear by the buffer lead (seeking back would then jump
                // forward). This way quick key presses add up reliably
                // without being distorted by late events.
                let dur = shared.now.lock().unwrap().duration_ms as i64;
                let base = shared
                    .seek_target
                    .lock()
                    .unwrap()
                    .map(|t| t as i64)
                    .unwrap_or_else(|| audible_position_ms(shared) as i64);
                let mut np = base + arg;
                if np < 0 {
                    np = 0;
                }
                // Never jump RIGHT to the end: a seek to the last second
                // makes librespot stop at once (EndOfTrack instead of
                // Seeked) — land shortly before it and let it run out.
                if dur > 2000 && np > dur - 2000 {
                    np = dur - 2000;
                } else if dur > 0 && np > dur {
                    np = dur;
                }
                let np = np as u32;

                // Connection dead? Then the jump needs audio data that will
                // never arrive over the old session. Instead of p.seek,
                // reconnect and reload the track right at the target.
                if !conn.alive() && has_cached_credentials() {
                    reset_trouble();
                    if let Ok(true) = ensure_live(conn, shared, Resume::At(np)).await {
                        return;
                    }
                    // Re-establishing failed: try with the old player.
                }

                *shared.seek_target.lock().unwrap() = Some(np);
                shared.now.lock().unwrap().position_ms = np; // show optimistically
                // Gate CLOSED + ring drained BEFORE the seek: from now on the
                // consumer discards the (still old) feed data until librespot
                // confirms the jump — no forward sound when seeking back.
                if let Some(feed) = shared.current_feed.lock().unwrap().as_ref() {
                    feed.set_gate(true);
                    feed.clear_pcm();
                }
                if let Some(p) = conn.player.as_ref() {
                    p.seek(np);
                }
                return;
            }
            if let Some(p) = conn.player.as_ref() {
                match action.as_str() {
                    "play" => p.play(),
                    "pause" => p.pause(),
                    "seek" => p.seek(arg.max(0) as u32),
                    _ => {}
                }
            }
        }
    }
}

/// Marker for "account without Premium" on the error path of
/// `connect_session`. An error text of its own could be translated and would
/// be unreliable to compare; this string is a key.
const NO_PREMIUM: &str = "nopremium";
/// No stored credentials (and no browser allowed).
const NOT_LOGGED_IN: &str = "notloggedin";
/// Spotify rejected the stored credentials.
const REJECTED: &str = "rejected";

/// Clears the stored credentials.
fn forget_credentials() {
    let had = CREDENTIALS.lock().unwrap().take().is_some();
    if had {
        CREDENTIALS_SERIAL.fetch_add(1, Ordering::SeqCst);
    }
}

// ---------------------------------------------------------------------------
// Stored credentials
// ---------------------------------------------------------------------------
//
// librespot would write its reusable credentials as plain JSON into the cache
// directory. Klangten keeps them itself instead (encrypted with DPAPI on
// Windows, a file only the user may read elsewhere): the host hands them in
// with set_stored_credentials before the first login and collects them after
// every change (stored_credentials_serial counts the changes). The library
// therefore never writes credentials to disk.

static CREDENTIALS: Mutex<Option<Credentials>> = Mutex::new(None);
static CREDENTIALS_SERIAL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Credentials from the host (JSON as written by `stored_credentials_json`).
/// An empty string clears them. Does not count as a change.
pub fn set_stored_credentials(json: &str) -> bool {
    if json.trim().is_empty() {
        *CREDENTIALS.lock().unwrap() = None;
        return true;
    }
    match serde_json::from_str::<Credentials>(json) {
        Ok(c) if !c.auth_data.is_empty() => {
            *CREDENTIALS.lock().unwrap() = Some(c);
            true
        }
        _ => false,
    }
}

/// The current reusable credentials as JSON, "" when there are none.
pub fn stored_credentials_json() -> String {
    match CREDENTIALS.lock().unwrap().as_ref() {
        Some(c) => serde_json::to_string(c).unwrap_or_default(),
        None => String::new(),
    }
}

/// Counts every change made by the library (login, logout, rejection).
pub fn stored_credentials_serial() -> u64 {
    CREDENTIALS_SERIAL.load(Ordering::SeqCst)
}

fn stored_credentials() -> Option<Credentials> {
    CREDENTIALS.lock().unwrap().clone()
}

/// Remembers the reusable credentials of a connected session.
fn remember_credentials(sess: &Session) {
    let auth_data = sess.auth_data();
    if auth_data.is_empty() {
        return;
    }
    let fresh = Credentials {
        username: Some(sess.username()),
        auth_type: librespot_protocol::authentication::AuthenticationType::AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS,
        auth_data,
    };
    let mut slot = CREDENTIALS.lock().unwrap();
    if slot.as_ref() != Some(&fresh) {
        *slot = Some(fresh);
        CREDENTIALS_SERIAL.fetch_add(1, Ordering::SeqCst);
    }
}

/// Waits briefly for Spotify to report the account type.
///
/// The product information arrives as a packet of its own, shortly AFTER
/// login — right after `connect` it is not known yet. We wait a few seconds
/// at most; if the information does not come, the account counts as usable
/// (better to play once too often than to reject a valid login).
async fn ist_premium(sess: &Session) -> bool {
    use std::time::{Duration, Instant};
    let bis = Instant::now() + Duration::from_secs(5);
    while Instant::now() < bis {
        if librespot_core::session::non_premium_seen() {
            return false;
        }
        if let Some(t) = sess.get_user_attribute("type") {
            return t == "premium";
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    !librespot_core::session::non_premium_seen()
}

/// True if stored credentials exist (silent login possible).
pub fn has_cached_credentials() -> bool {
    CREDENTIALS.lock().unwrap().is_some()
}

// ---------------------------------------------------------------------------
// Connection: establish, check, re-establish
// ---------------------------------------------------------------------------
//
// Spotify drops the connection after a long idle period, on network changes
// and while the computer sleeps. librespot does NOT reconnect by itself; at
// most it declares the session invalid — and even that only when its
// keep-alive timer expires. That timer runs on the monotonic clock, which
// stands still during sleep on macOS: after waking up, a dead session still
// counted as healthy for minutes, and librespot's HTTP requests (without any
// time limit) hung on dead connections.
//
// Hence, on EVERY access:
//   1. ensure_live: session invalid OR no packet from the access point for
//      STALE_AFTER_MS (wall clock) → silently reconnect (stored
//      credentials, never a browser).
//   2. Every single request has a time limit (REQ_TIMEOUT, `net`).
//   3. If a call still fails with a NETWORK error, reconnect once and retry
//      (`run_query`).
// Re-establishing also rebuilds the player (it is tied to its session) and
// resumes a running track at the audible position in the SAME feed — the
// host's audio stream only notices a short gap.

/// Session + player. The player is tied to exactly this session.
#[derive(Default)]
struct Conn {
    session: Option<Session>,
    player: Option<Arc<Player>>,
}

impl Conn {
    fn alive(&self) -> bool {
        self.player.is_some() && self.session.as_ref().is_some_and(session_alive)
    }
}

fn session_alive(s: &Session) -> bool {
    !s.is_invalid() && s.millis_since_last_packet() < STALE_AFTER_MS
}

/// Has the current attempt of a command seen a NETWORK problem (timeout,
/// connection error, expired token)? Only then is reconnecting + retrying
/// worthwhile — an album that simply was not found should not interrupt the
/// music that is playing. Global, because the metadata requests run in tokio
/// tasks of their own; the engine processes one command after the other
/// anyway. At the same time the emergency brake: while it is set, further
/// requests are not even sent (otherwise a list of 100 tracks would wait out
/// REQ_TIMEOUT 100 times).
static NET_TROUBLE: AtomicBool = AtomicBool::new(false);

fn reset_trouble() {
    NET_TROUBLE.store(false, Ordering::SeqCst);
}

fn trouble() -> bool {
    NET_TROUBLE.load(Ordering::SeqCst)
}

fn note_trouble(what: &str) {
    if !NET_TROUBLE.swap(true, Ordering::SeqCst) {
        crate::klog!("[spotify] network problem: {}", what);
    }
}

/// Error kinds that may hide a broken connection (as opposed to "not
/// found", "not allowed", "unreadable").
fn is_net_error(e: &librespot_core::Error) -> bool {
    matches!(
        e.kind,
        ErrorKind::Unavailable
            | ErrorKind::DeadlineExceeded
            | ErrorKind::Aborted
            | ErrorKind::Cancelled
            | ErrorKind::Unauthenticated
            | ErrorKind::Internal
            | ErrorKind::Unknown
    )
}

/// A librespot request with a time limit. NET_TROUBLE records network errors
/// and timeouts; other errors (not found …) do not.
async fn net<T>(
    what: &str,
    fut: impl std::future::Future<Output = Result<T, librespot_core::Error>>,
) -> Option<T> {
    if trouble() {
        return None; // connection already known to be broken: do not wait any longer
    }
    match tokio::time::timeout(REQ_TIMEOUT, fut).await {
        Ok(Ok(v)) => Some(v),
        Ok(Err(e)) => {
            if is_net_error(&e) {
                note_trouble(&format!("{}: {}", what, e));
            }
            None
        }
        Err(_) => {
            note_trouble(&format!(
                "{}: no answer after {} s",
                what,
                REQ_TIMEOUT.as_secs()
            ));
            None
        }
    }
}

/// What happens to the running track after re-establishing.
enum Resume {
    /// Resume at the audible position.
    Keep,
    /// Resume at this position (ms) — seeking over a dead connection.
    At(u32),
    /// Do not resume (another track is about to come anyway).
    Drop,
}

struct ResumePoint {
    uri: String,
    pos: u32,
    play: bool,
    feed: Arc<PcmFeed>,
}

/// Is a track playing that should continue after re-establishing?
fn resume_point(shared: &Arc<Shared>, at: Option<u32>) -> Option<ResumePoint> {
    let feed = shared.current_feed.lock().unwrap().clone()?;
    if feed.is_done() || feed.is_cancelled() {
        return None;
    }
    let (uri, state) = {
        let n = shared.now.lock().unwrap();
        (n.uri.clone(), n.state.clone())
    };
    if uri.is_empty() {
        return None;
    }
    let play = match state.as_str() {
        "playing" | "loading" => true,
        "paused" => false,
        _ => return None,
    };
    let pos = at.unwrap_or_else(|| {
        let t = *shared.seek_target.lock().unwrap();
        t.unwrap_or_else(|| audible_position_ms(shared))
    });
    Some(ResumePoint {
        uri,
        pos,
        play,
        feed,
    })
}

/// Resumes the track on the NEW player at `rp.pos` — into the same feed the
/// host is playing right now. Uses the seek mechanism: gate closed until
/// librespot reports the target position (finish_seek), so that nothing left
/// over from the old player becomes audible.
fn resume_track(conn: &Conn, shared: &Arc<Shared>, rp: ResumePoint) {
    let player = match conn.player.as_ref() {
        Some(p) => p,
        None => return,
    };
    let uri = match SpotifyUri::from_uri(&rp.uri) {
        Ok(u) => u,
        Err(_) => return,
    };
    if let Some(slot) = SINK_SLOT.lock().unwrap().as_ref() {
        *slot.lock().unwrap() = Some(rp.feed.clone());
    }
    *shared.seek_target.lock().unwrap() = Some(rp.pos);
    shared.now.lock().unwrap().position_ms = rp.pos;
    rp.feed.set_gate(true);
    rp.feed.clear_pcm();
    crate::klog!(
        "[spotify] resuming {} at {} s",
        rp.uri,
        rp.pos / 1000
    );
    player.load(uri, rp.play, rp.pos);
}

/// Clears away the old session + player WITHOUT blocking the engine thread.
///
/// `Player::drop` waits (join) for the player thread. That thread can be
/// stuck in FeedSink::write — the ring is full because the host paused the
/// track — and would then never get free. In the async context this would
/// hold the whole engine thread: no search, no track, nothing any more. So
/// the drop happens on a throwaway thread; the old sink first has its slot
/// taken away and discards everything that follows.
fn retire(conn: &mut Conn) {
    if let Some(slot) = SINK_SLOT.lock().unwrap().take() {
        *slot.lock().unwrap() = None;
    }
    if let Some(p) = conn.player.take() {
        p.stop();
        let _ = std::thread::Builder::new()
            .name("klangten-spotify-old".into())
            .spawn(move || drop(p));
    }
    if let Some(s) = conn.session.take() {
        if !s.is_invalid() {
            s.shutdown();
        }
    }
}

/// Before every request/playback, makes sure the session is ALIVE; otherwise
/// silently rebuilds it from the stored credentials (never a browser: a
/// background request must not open one). Ok(true) = reconnected.
async fn ensure_live(conn: &mut Conn, shared: &Arc<Shared>, resume: Resume) -> Result<bool, String> {
    if conn.alive() {
        return Ok(false);
    }
    match conn.session.as_ref() {
        Some(s) if s.is_invalid() => {
            crate::klog!("[spotify] session ended by librespot — reconnecting…");
        }
        Some(s) => {
            crate::klog!(
                "[spotify] no sign of life from the access point for {} s — reconnecting…",
                s.millis_since_last_packet() / 1000
            );
        }
        None => {}
    }
    if !has_cached_credentials() {
        return Err("not logged in to Spotify".to_string());
    }
    reconnect(conn, shared, false, resume).await.map(|_| true)
}

/// Builds a new session and ONLY THEN replaces the old one ("make before
/// break"): if re-establishing fails (network still gone), everything stays
/// as it was — a track that keeps playing from the buffer is not cut off.
async fn reconnect(
    conn: &mut Conn,
    shared: &Arc<Shared>,
    interactive: bool,
    resume: Resume,
) -> Result<(), String> {
    let sess = match connect_session(interactive).await {
        Ok(s) => s,
        Err(e) => {
            if e == NO_PREMIUM {
                retire(conn);
                shared.set_login(LoginState::NoPremium);
            } else if e == NOT_LOGGED_IN {
                shared.set_login(LoginState::LoggedOut);
            } else if e == REJECTED {
                // Credentials invalid: the host should log in again on the
                // next open (with the browser then).
                shared.set_login(LoginState::Failed(e.clone()));
            }
            // Network error: the state stays; the next access tries again.
            return Err(e);
        }
    };
    // Take the position of the running track only NOW — establishing took time.
    let rp = match resume {
        Resume::Keep => resume_point(shared, None),
        Resume::At(ms) => resume_point(shared, Some(ms)),
        Resume::Drop => None,
    };
    retire(conn);
    install_player(conn, shared, sess);
    shared.set_login(LoginState::LoggedIn);
    crate::klog!("[spotify] connected");
    if let Some(rp) = rp {
        resume_track(conn, shared, rp);
    }
    Ok(())
}

/// Connects a session: stored credentials, otherwise (only when
/// `interactive`) OAuth in the browser. With a time limit, so that a dead
/// network does not hold the engine thread.
async fn connect_session(interactive: bool) -> Result<Session, String> {
    // No credentials and no audio files on disk - the cache keeps only
    // librespot's volume file. Credentials come from the host
    // (stored_credentials), and the audio is streamed, never stored.
    let dir = cache_dir();
    let _ = std::fs::create_dir_all(&dir);
    let cache = Cache::new(None, Some(dir.clone()), None, None)
        .map_err(|e| format!("Cache: {}", e))?;

    let credentials = match stored_credentials() {
        Some(c) => c,
        None if interactive => oauth_login().await?,
        None => return Err(NOT_LOGGED_IN.to_string()),
    };

    let sess = Session::new(SessionConfig::default(), Some(cache));
    // Reset before EVERY attempt: the flag is global and would otherwise
    // survive a change of account.
    librespot_core::session::reset_non_premium();
    match tokio::time::timeout(CONNECT_TIMEOUT, sess.connect(credentials, true)).await {
        Ok(Ok(())) => {}
        // Stored credentials rejected → once more via OAuth — but ONLY on an
        // explicit login. A network error is NO reason for the browser (it
        // used to be opened by every failed re-establishment, and the engine
        // thread then waited forever for the login).
        Ok(Err(e)) if e.kind == ErrorKind::PermissionDenied => {
            if !interactive {
                crate::klog!("[spotify] stored login rejected: {e}");
                return Err(REJECTED.to_string());
            }
            crate::klog!("[spotify] connecting with stored credentials failed: {e}. OAuth…");
            let fresh = oauth_login().await?;
            match tokio::time::timeout(CONNECT_TIMEOUT, sess.connect(fresh, true)).await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => return Err(format!("Connection: {}", e)),
                Err(_) => return Err("Connection: timed out".to_string()),
            }
        }
        Ok(Err(e)) => return Err(format!("Connection: {}", e)),
        Err(_) => {
            return Err(format!(
                "Connection: no answer after {} s",
                CONNECT_TIMEOUT.as_secs()
            ))
        }
    }

    // Without Premium Spotify delivers no audio data — librespot cannot do
    // anything with such an account and upstream ends the whole process at
    // this point (see vendor/librespot-core/PATCHES.md). We stop here instead,
    // BEFORE a player is created.
    //
    // The credentials have to go as well: the host logs in silently with
    // them on startup — a free account in the store would mean running into
    // the same wall again on every start.
    if !ist_premium(&sess).await {
        forget_credentials();
        sess.shutdown();
        return Err(NO_PREMIUM.to_string());
    }
    remember_credentials(&sess);
    Ok(sess)
}

/// Builds the player for this session; the sink writes into a fresh slot
/// (SINK_SLOT), which open_track or resume_track fills.
fn install_player(conn: &mut Conn, shared: &Arc<Shared>, sess: Session) {
    let slot: Arc<Mutex<Option<Arc<PcmFeed>>>> = Arc::new(Mutex::new(None));
    *SINK_SLOT.lock().unwrap() = Some(slot.clone());

    let player_config = PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        gapless: true,
        // Volume normalisation (like Spotify's "Normalize volume", on by
        // default there): librespot brings tracks to a uniform, moderate
        // level via ReplayGain — otherwise it outputs Spotify's very loud
        // masters at full level and drowns out the host's speech and sounds
        // (it seemed as if Spotify ignored the host's volume). The host's own
        // volume control still applies on top.
        normalisation: true,
        position_update_interval: Some(Duration::from_secs(1)),
        ..Default::default()
    };
    let sink_slot = slot.clone();
    let p = Player::new(
        player_config,
        sess.clone(),
        Box::new(NoOpVolume) as Box<dyn VolumeGetter + Send>,
        move || -> Box<dyn Sink> { Box::new(FeedSink { slot: sink_slot.clone() }) },
    );
    spawn_event_task(p.get_player_event_channel(), shared.clone());
    conn.player = Some(p);
    conn.session = Some(sess);
}

/// Runs a query with a live session; if it fails with a NETWORK error (see
/// NET_TROUBLE), reconnects once and retries. Worst case: REQ_TIMEOUT +
/// CONNECT_TIMEOUT + REQ_TIMEOUT — well below QUERY_TIMEOUT, so the answer
/// still reaches the caller.
async fn run_query<T, F, Fut>(
    conn: &mut Conn,
    shared: &Arc<Shared>,
    what: &str,
    op: F,
) -> Option<T>
where
    F: Fn(Session) -> Fut,
    Fut: std::future::Future<Output = Option<T>>,
{
    reset_trouble();
    let fresh = match ensure_live(conn, shared, Resume::Keep).await {
        Ok(f) => f,
        Err(e) => {
            crate::klog!("[spotify] {}: {}", what, e);
            return None;
        }
    };
    let out = op(conn.session.clone()?).await;
    if out.is_some() || !trouble() {
        return out;
    }
    if fresh {
        crate::klog!("[spotify] {}: fails even with a fresh connection", what);
        return None;
    }
    crate::klog!("[spotify] {}: network problem — reconnecting and trying once more", what);
    reset_trouble();
    if let Err(e) = reconnect(conn, shared, false, Resume::Keep).await {
        crate::klog!("[spotify] {}: re-establishing failed: {}", what, e);
        return None;
    }
    op(conn.session.clone()?).await
}

/// Shared sink slot: the one place where open_track puts the new feed and
/// from which the sink of the CURRENT player reads. Separate from shared
/// because the sink already needs it when the player is built. Every player
/// gets a slot of its own; retire empties the old one so that a superseded
/// player no longer writes into the host's feed.
static SINK_SLOT: Mutex<Option<Arc<Mutex<Option<Arc<PcmFeed>>>>>> = Mutex::new(None);

/// Page the browser shows after a successful login (the host sets a
/// translated one through ks_set_login_page).
static LOGIN_PAGE: Mutex<String> = Mutex::new(String::new());

pub fn set_login_page(html: &str) {
    *LOGIN_PAGE.lock().unwrap() = html.to_string();
}

fn login_page() -> String {
    let page = LOGIN_PAGE.lock().unwrap().clone();
    if page.trim().is_empty() {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Klangten</title></head><body><h1>Klangten is connected to Spotify.</h1><p>You can close this window.</p></body></html>".to_string()
    } else {
        page
    }
}

/// Port of OAUTH_REDIRECT.
const OAUTH_PORT: u16 = 5588;

/// Set while a browser login waits for Spotify's redirect.
static OAUTH_WAITING: AtomicBool = AtomicBool::new(false);

/// Ends a browser login that is still waiting. librespot's redirect listener
/// blocks until a request arrives; without one it would hold the port (and
/// the engine thread would wait until OAUTH_TIMEOUT). A request without a
/// code makes it give up at once.
pub fn cancel_login() {
    if !OAUTH_WAITING.load(Ordering::SeqCst) {
        return;
    }
    use std::io::Write;
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], OAUTH_PORT));
    if let Ok(mut stream) = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(1)) {
        let _ = stream.write_all(b"GET /login?error=cancelled HTTP/1.0\r\n\r\n");
    }
}

/// OAuth PKCE login in the browser (blocking → spawn_blocking), with a time
/// limit: if the user gives up, the engine thread should not wait forever.
async fn oauth_login() -> Result<Credentials, String> {
    OAUTH_WAITING.store(true, Ordering::SeqCst);
    let task = tokio::task::spawn_blocking(|| {
        use librespot_oauth::OAuthClientBuilder;
        let client = OAuthClientBuilder::new(SPOTIFY_CLIENT_ID, OAUTH_REDIRECT, OAUTH_SCOPES.to_vec())
            .open_in_browser()
            .with_custom_message(&login_page())
            .build()
            .map_err(|e| format!("OAuth client: {}", e))?;
        let token = client
            .get_access_token()
            .map_err(|e| format!("OAuth: {}", e))?;
        Ok(Credentials::with_access_token(&token.access_token))
    });
    let result = match tokio::time::timeout(OAUTH_TIMEOUT, task).await {
        Ok(r) => r.map_err(|e| format!("OAuth task: {}", e)).and_then(|x| x),
        Err(_) => {
            // Free the port: the listener thread is still waiting.
            cancel_login();
            Err("OAuth: no login in the browser".to_string())
        }
    };
    OAUTH_WAITING.store(false, Ordering::SeqCst);
    result
}

// ---- Metadata / search / library / playlists ----

fn track_to_info(track: &Track, uri: &str) -> TrackInfo {
    TrackInfo {
        uri: uri.to_string(),
        title: track.name.clone(),
        artist: track
            .artists
            .0
            .iter()
            .map(|a| a.name.clone())
            .collect::<Vec<_>>()
            .join(", "),
        album: track.album.name.clone(),
        duration_ms: track.duration.max(0) as u32,
        artist_uri: track
            .artists
            .0
            .first()
            .and_then(|a| a.id.to_uri().ok())
            .unwrap_or_default(),
        album_uri: track.album.id.to_uri().unwrap_or_default(),
    }
}

async fn fetch_track(session: &Session, uri_str: &str) -> Option<TrackInfo> {
    let uri = SpotifyUri::from_uri(uri_str).ok()?;
    // Audiobook chapters and podcast episodes are EPISODES, not tracks —
    // without this branch name and duration would stay empty (and seeking
    // would be blind).
    if uri_str.starts_with("spotify:episode:") {
        let ep = net("Episode", librespot_metadata::Episode::get(session, &uri)).await?;
        return Some(TrackInfo {
            uri: uri_str.to_string(),
            title: ep.name.clone(),
            artist: ep.show_name.clone(),
            album: ep.show_name.clone(),
            duration_ms: ep.duration.max(0) as u32,
            artist_uri: String::new(),
            album_uri: String::new(),
        });
    }
    let track = net("Track", Track::get(session, &uri)).await?;
    Some(track_to_info(&track, uri_str))
}

/// One row of the typed search.
#[derive(Clone, Debug, Default)]
pub struct SearchRow {
    /// track | artist | album | playlist | audiobook | podcast
    pub kind: String,
    pub uri: String,
    pub name: String,
    /// Second line: performer, author, owner — depending on the kind.
    pub sub: String,
    pub duration_ms: u32,
    /// Identifiers for a track's context menu ("go to artist", "go to
    /// album"). For an album only `artist_uri` is set.
    pub artist_uri: String,
    pub album_uri: String,
}

/// The hash of the web player's persisted query "searchDesktop".
/// Spotify allows ONLY registered queries through `pathfinder`; when the web
/// player changes its version, the service answers "PersistedQueryNotFound".
/// The search then falls back to the context route (tracks only) — so it
/// stays usable in any case.
const SEARCH_QUERY_HASH: &str =
    "d9f785900f0710b31c07818d617f4f7600c1e21217e80f5b043d1e78d74e6026";

/// Typed search through `pathfinder` — the same query the web player uses.
/// It is the ONLY route to artists, albums, playlists, audiobooks and
/// podcasts: spclient only knows track search, and the public Web API
/// rejects librespot's client ID (429 on every request, even /v1/me —
/// measured 2026-08-28). Authentication uses the login5 token of the running
/// session plus spclient's client token.
async fn search_typed(
    session: &Session,
    query: &str,
    limit: usize,
) -> Option<Vec<SearchRow>> {
    let token = net("login5 token", session.login5().auth_token()).await?;
    let ctoken = net("client-token", session.spclient().client_token()).await?;
    let vars = serde_json::json!({
        "searchTerm": query,
        "offset": 0,
        "limit": limit,
        "numberOfTopResults": limit,
        "includeAudiobooks": true,
    })
    .to_string();
    let ext = serde_json::json!({
        "persistedQuery": { "version": 1, "sha256Hash": SEARCH_QUERY_HASH }
    })
    .to_string();

    let client = reqwest::Client::builder().timeout(REQ_TIMEOUT).build().ok()?;
    let resp = client
        .get("https://api-partner.spotify.com/pathfinder/v1/query")
        .query(&[
            ("operationName", "searchDesktop"),
            ("variables", vars.as_str()),
            ("extensions", ext.as_str()),
        ])
        .bearer_auth(&token.access_token)
        .header("client-token", ctoken)
        .header("app-platform", "WebPlayer")
        .send()
        .await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) => {
            if e.is_timeout() || e.is_connect() || e.is_request() {
                note_trouble(&format!("pathfinder: {}", e));
            }
            return None;
        }
    };
    if !resp.status().is_success() {
        crate::klog!("[spotify] search via pathfinder: HTTP {}", resp.status());
        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            note_trouble("pathfinder: token expired");
        }
        return None;
    }
    let text = match resp.text().await {
        Ok(t) => t,
        Err(e) => {
            note_trouble(&format!("pathfinder: {}", e));
            return None;
        }
    };
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let sv = v.get("data")?.get("searchV2")?;
    if sv.is_null() {
        return None;
    }

    let mut out: Vec<SearchRow> = Vec::new();

    // --- Tracks (tracksV2 wraps each row once more in "item")
    if let Some(items) = sv.pointer("/tracksV2/items").and_then(|x| x.as_array()) {
        for it in items.iter().take(limit) {
            let d = match it.pointer("/item/data") {
                Some(d) => d,
                None => continue,
            };
            let uri = d.get("uri").and_then(|x| x.as_str()).unwrap_or("");
            if uri.is_empty() {
                continue;
            }
            let artists: Vec<String> = d
                .pointer("/artists/items")
                .and_then(|x| x.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.pointer("/profile/name").and_then(|n| n.as_str()))
                        .map(|s| s.to_string())
                        .collect()
                })
                .unwrap_or_default();
            out.push(SearchRow {
                kind: "track".into(),
                uri: uri.to_string(),
                name: d.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                sub: artists.join(", "),
                duration_ms: d
                    .pointer("/duration/totalMilliseconds")
                    .and_then(|x| x.as_u64())
                    .unwrap_or(0) as u32,
                artist_uri: d
                    .pointer("/artists/items/0/uri")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string(),
                album_uri: d
                    .pointer("/albumOfTrack/uri")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string(),
            });
        }
    }

    // --- the other categories: all follow the same pattern items[].data
    let sparten: [(&str, &str); 5] = [
        ("artists", "artist"),
        ("albumsV2", "album"),
        ("playlists", "playlist"),
        ("audiobooks", "audiobook"),
        ("podcasts", "podcast"),
    ];
    for (feld, art) in sparten {
        let items = match sv.pointer(&format!("/{feld}/items")).and_then(|x| x.as_array()) {
            Some(i) => i,
            None => continue,
        };
        for it in items.iter().take(limit) {
            let d = match it.get("data") {
                Some(d) => d,
                None => continue,
            };
            let uri = d.get("uri").and_then(|x| x.as_str()).unwrap_or("");
            if uri.is_empty() {
                continue;
            }
            // Name: artists carry it under profile.name, all others directly.
            let name = d
                .pointer("/profile/name")
                .or_else(|| d.get("name"))
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            // Second line: album -> performer, audiobook -> author,
            // playlist -> owner, podcast -> publisher.
            let sub = d
                .pointer("/artists/items/0/profile/name")
                .or_else(|| d.pointer("/authorsV2/0/name"))
                .or_else(|| d.pointer("/ownerV2/data/name"))
                .or_else(|| d.get("publisher"))
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            out.push(SearchRow {
                kind: art.into(),
                uri: uri.to_string(),
                name,
                sub,
                duration_ms: 0,
                // An album leads to its artist; everything else has
                // nowhere further to lead.
                artist_uri: d
                    .pointer("/artists/items/0/uri")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string(),
                album_uri: String::new(),
            });
        }
    }
    Some(out)
}

/// An audiobook or podcast with its chapters/episodes. Spotify lists both
/// as a "show": the search returns `spotify:show:…`, the chapters are
/// episodes — and librespot can play episodes.
async fn show_details(session: &Session, uri_str: &str, limit: usize) -> Option<AlbumDetails> {
    let uri = SpotifyUri::from_uri(uri_str).ok()?;
    let sh = net("Show", librespot_metadata::Show::get(session, &uri)).await?;
    let uris: Vec<String> = sh
        .episodes
        .0
        .iter()
        .filter_map(|e| e.to_uri().ok())
        .take(limit)
        .collect();
    Some(AlbumDetails {
        uri: uri_str.to_string(),
        name: sh.name.clone(),
        artist: sh.publisher.clone(),
        tracks: tracks_from_uris(session, &uris, limit).await?,
    })
}

/// Upper limit for track lists (library, playlist). Not meant as a saving
/// measure but as an emergency brake against degenerate lists — the normal
/// case should be loaded COMPLETELY. If it is reached, the log says so.
pub const MAX_TRACKS: usize = 10_000;

/// Fetches metadata IN PARALLEL (at most 8 at a time): sequentially, the
/// library (100 × Track::get, one round trip each) took ~3 s even with a data
/// centre connection and 10-30 s on a home line. The order is preserved
/// (index join), failures simply drop out.
/// None = the connection failed along the way (NET_TROUBLE) — then better
/// reconnect and retry than show a list with holes.
async fn tracks_from_uris(session: &Session, uris: &[String], limit: usize) -> Option<Vec<TrackInfo>> {
    if uris.len() > limit {
        crate::klog!(
            "[spotify] list truncated: {} tracks available, {} loaded (limit)",
            uris.len(),
            limit
        );
    }
    let sem = Arc::new(tokio::sync::Semaphore::new(8));
    let mut handles = Vec::new();
    for u in uris.iter().take(limit) {
        let sess = session.clone();
        let u = u.clone();
        let sem = sem.clone();
        handles.push(tokio::spawn(async move {
            let _permit = sem.acquire().await;
            fetch_track(&sess, &u).await
        }));
    }
    let mut out = Vec::new();
    for h in handles {
        if let Ok(Some(t)) = h.await {
            out.push(t);
        }
    }
    if trouble() {
        return None;
    }
    Some(out)
}

/// Free-text search through the internal spclient context (no Web API token).
async fn search_tracks(session: &Session, query: &str, limit: usize) -> Option<Vec<TrackInfo>> {
    let ctx_uri = search_context_uri(query);
    let ctx = net("Search context", session.spclient().get_context(&ctx_uri)).await?;
    let mut uris = Vec::new();
    for page in ctx.pages.iter() {
        for t in page.tracks.iter() {
            if let Some(u) = t.uri.as_deref() {
                uris.push(u.to_string());
            }
        }
    }
    tracks_from_uris(session, &uris, limit).await
}

/// Recommendations for ONE track — the "song radio" of the Spotify client.
/// spclient answers `get_radio_for_track` with the URI of a playlist created
/// for this purpose ("inspired by"); its tracks ARE the recommendations.
/// (The public Web API /v1/recommendations is blocked for librespot's client
/// ID — checked on 2026-08-28: 429 on every request.)
async fn track_radio(session: &Session, track_uri: &str, limit: usize) -> Option<Vec<TrackInfo>> {
    let uri = SpotifyUri::from_uri(track_uri).ok()?;
    let bytes = net("Song radio", session.spclient().get_radio_for_track(&uri)).await?;
    let v: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let items = v.get("mediaItems")?.as_array()?;
    let mut direkt = Vec::new();
    for it in items {
        let u = it.get("uri").and_then(|u| u.as_str()).unwrap_or("");
        if u.starts_with("spotify:playlist:") {
            if let Some(t) = playlist_tracks(session, u, limit).await {
                if !t.is_empty() {
                    return Some(t);
                }
            }
        } else if u.starts_with("spotify:track:") {
            direkt.push(u.to_string());
        }
    }
    if direkt.is_empty() {
        return None;
    }
    tracks_from_uris(session, &direkt, limit).await
}

/// Fetches the names for album URIs (in parallel, like tracks_from_uris).
async fn named_albums(session: &Session, uris: &[String]) -> Vec<NamedItem> {
    let sem = Arc::new(tokio::sync::Semaphore::new(8));
    let mut handles = Vec::new();
    for u in uris.iter() {
        let sess = session.clone();
        let u = u.clone();
        let sem = sem.clone();
        handles.push(tokio::spawn(async move {
            let _permit = sem.acquire().await;
            let name = match SpotifyUri::from_uri(&u) {
                Ok(uri) => match net("Album", librespot_metadata::Album::get(&sess, &uri)).await {
                    Some(al) => al.name.clone(),
                    None => u.clone(),
                },
                Err(_) => u.clone(),
            };
            NamedItem { uri: u, name }
        }));
    }
    let mut out = Vec::new();
    for h in handles {
        if let Ok(n) = h.await {
            out.push(n);
        }
    }
    out
}

/// Artist page: name, biography, most popular tracks, albums, related
/// artists — all from the metadata librespot delivers anyway.
async fn artist_details(
    session: &Session,
    artist_uri: &str,
    limit: usize,
) -> Option<ArtistDetails> {
    let uri = SpotifyUri::from_uri(artist_uri).ok()?;
    let a = net("Artist", librespot_metadata::Artist::get(session, &uri)).await?;

    // Most popular tracks: the list for the user's OWN country; otherwise the
    // first one available (Spotify keeps them per market).
    let land = session.country();
    let mut top_uris: Vec<String> = Vec::new();
    let mut ersatz: Vec<String> = Vec::new();
    for tt in a.top_tracks.0.iter() {
        let uris: Vec<String> = tt.tracks.0.iter().filter_map(|u| u.to_uri().ok()).collect();
        if tt.country == land {
            top_uris = uris;
            break;
        }
        if ersatz.is_empty() {
            ersatz = uris;
        }
    }
    if top_uris.is_empty() {
        top_uris = ersatz;
    }
    top_uris.truncate(limit);
    let top = tracks_from_uris(session, &top_uris, limit).await?;

    // Albums: only the current release of each group.
    let mut album_uris: Vec<String> = a
        .albums_current()
        .filter_map(|u| u.to_uri().ok())
        .collect();
    album_uris.truncate(limit);
    let albums = named_albums(session, &album_uris).await;
    if trouble() {
        return None;
    }

    let related: Vec<NamedItem> = a
        .related
        .0
        .iter()
        .filter_map(|r| {
            r.id.to_uri().ok().map(|u| NamedItem {
                uri: u,
                name: r.name.clone(),
            })
        })
        .take(limit)
        .collect();

    Some(ArtistDetails {
        uri: artist_uri.to_string(),
        name: a.name.clone(),
        biography: a
            .biographies
            .0
            .first()
            .map(|b| b.text.clone())
            .unwrap_or_default(),
        top,
        albums,
        related,
    })
}

/// An album with its tracks (in the order of discs/sides).
async fn album_details(session: &Session, album_uri: &str, limit: usize) -> Option<AlbumDetails> {
    let uri = SpotifyUri::from_uri(album_uri).ok()?;
    let al = net("Album", librespot_metadata::Album::get(session, &uri)).await?;
    let uris: Vec<String> = al.tracks().filter_map(|u| u.to_uri().ok()).collect();
    Some(AlbumDetails {
        uri: album_uri.to_string(),
        name: al.name.clone(),
        artist: al
            .artists
            .0
            .iter()
            .map(|x| x.name.clone())
            .collect::<Vec<_>>()
            .join(", "),
        tracks: tracks_from_uris(session, &uris, limit).await?,
    })
}

async fn liked_tracks(session: &Session, limit: usize) -> Option<Vec<TrackInfo>> {
    let ctx_uri = format!("spotify:user:{}:collection", session.username());
    let ctx = net("Library", session.spclient().get_context(&ctx_uri)).await?;
    let mut uris = Vec::new();
    for page in ctx.pages.iter() {
        for t in page.tracks.iter() {
            if let Some(u) = t.uri.as_deref() {
                uris.push(u.to_string());
            }
        }
    }
    tracks_from_uris(session, &uris, limit).await
}

async fn playlist_tracks(session: &Session, uri_str: &str, limit: usize) -> Option<Vec<TrackInfo>> {
    let uri = SpotifyUri::from_uri(uri_str).ok()?;
    let pl = net("Playlist", librespot_metadata::Playlist::get(session, &uri)).await?;
    let uris: Vec<String> = pl
        .tracks()
        .filter_map(|u| u.to_uri().ok())
        .collect();
    tracks_from_uris(session, &uris, limit).await
}

/// The user's own playlists: rootlist (protobuf) → playlist URIs → fetch names.
async fn user_playlists(session: &Session, limit: usize) -> Option<Vec<PlaylistInfo>> {
    use librespot_protocol::playlist4_external::SelectedListContent;
    use protobuf::Message;

    let bytes = net("Playlist list", session.spclient().get_rootlist(0, Some(limit))).await?;
    let slc = SelectedListContent::parse_from_bytes(&bytes).ok()?;
    let mut uris = Vec::new();
    if let Some(contents) = slc.contents.as_ref() {
        for item in contents.items.iter() {
            let uri_str = item.uri();
            if !uri_str.starts_with("spotify:playlist:") {
                continue; // skip start-group/end-group (folder markers)
            }
            if uris.len() >= limit {
                break;
            }
            uris.push(uri_str.to_string());
        }
    }
    // Fetch the names in parallel (like tracks_from_uris) — sequentially this
    // cost one round trip per playlist.
    let sem = Arc::new(tokio::sync::Semaphore::new(8));
    let mut handles = Vec::new();
    for uri_str in uris {
        let sess = session.clone();
        let sem = sem.clone();
        handles.push(tokio::spawn(async move {
            let _permit = sem.acquire().await;
            let name = match SpotifyUri::from_uri(&uri_str) {
                Ok(uri) => match net("Playlist", librespot_metadata::Playlist::get(&sess, &uri)).await {
                    Some(pl) => pl.name().to_string(),
                    None => uri_str.clone(),
                },
                Err(_) => uri_str.clone(),
            };
            PlaylistInfo { uri: uri_str, name }
        }));
    }
    let mut out = Vec::new();
    for h in handles {
        if let Ok(p) = h.await {
            out.push(p);
        }
    }
    if trouble() {
        return None; // names missing because of the connection: reconnect, retry
    }
    Some(out)
}

/// Opens a track: create a new feed (format set at once, so the host does not
/// have to wait for it), cancel the old one, put it into the sink slot +
/// shared, load.
async fn open_track(
    session: &Option<Session>,
    player: &Option<Arc<Player>>,
    shared: &Arc<Shared>,
    uri_str: &str,
    start_ms: u32,
) -> Option<Arc<PcmFeed>> {
    let sess = session.as_ref()?;
    let player = player.as_ref()?;
    let uri = SpotifyUri::from_uri(uri_str).ok()?;

    // Shut down the old feed.
    if let Some(old) = shared.current_feed.lock().unwrap().as_ref() {
        old.cancel();
        old.mark_done();
    }

    let feed = PcmFeed::new_arc();
    feed.set_format(CH, SR);
    // Small ring (~2 s instead of the 10 s default): keeps librespot's decode
    // lead small (backpressure), so that EndOfTrack fires only shortly before
    // the audible end and the audible position stays close to the real one.
    feed.set_ring_max((SR * CH * 2) as usize);
    feed.set_state_ext("ok");

    // Into BOTH records: sink slot (where the sink reads from) + shared.
    if let Some(slot) = SINK_SLOT.lock().unwrap().as_ref() {
        *slot.lock().unwrap() = Some(feed.clone());
    }
    *shared.current_feed.lock().unwrap() = Some(feed.clone());

    // Remember the CANONICAL URI: the player events deliver the track URI via
    // SpotifyUri::to_uri() — exactly this form must be in now.uri, otherwise
    // is_current() never matches (position tracking + end detection dead, and
    // seeking would always jump from position 0).
    let canonical = uri.to_uri().unwrap_or_else(|_| uri_str.to_string());
    // Set now playing minimally (a background task fills in title/artist/
    // duration) — so ks_open does NOT block on a metadata request. This
    // matters because the host opens a stream on EVERY track change.
    {
        let mut n = shared.now.lock().unwrap();
        n.uri = canonical.clone();
        n.title = String::new();
        n.artist = String::new();
        n.album = String::new();
        n.duration_ms = 0;
        n.position_ms = start_ms;
        n.state = "loading".into();
    }
    // New track: no seek in progress any more. The audible base is the start
    // position — for a resumed audiobook, therefore, not 0.
    *shared.seek_target.lock().unwrap() = None;
    *shared.audible_base_ms.lock().unwrap() = start_ms;
    player.load(uri, true, start_ms);

    // Fill in the metadata (above all the duration, for seeking) asynchronously.
    {
        let sess2 = sess.clone();
        let shared2 = shared.clone();
        let want = canonical.clone();
        tokio::spawn(async move {
            if let Some(info) = fetch_track(&sess2, &want).await {
                let mut n = shared2.now.lock().unwrap();
                if n.uri == want {
                    // only if the same track is still playing
                    n.title = info.title;
                    n.artist = info.artist;
                    n.album = info.album;
                    n.duration_ms = info.duration_ms;
                }
            }
        });
    }

    Some(feed)
}

/// Builds a `spotify:search:` context URI (words joined with `+`, the rest percent-encoded).
fn search_context_uri(query: &str) -> String {
    use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
    const QUERY_SET: &AsciiSet = &NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'_')
        .remove(b'.')
        .remove(b'~');
    let encoded: Vec<String> = query
        .split(' ')
        .filter(|w| !w.is_empty())
        .map(|word| utf8_percent_encode(word, QUERY_SET).to_string())
        .collect();
    format!("spotify:search:{}", encoded.join("+"))
}

// ---------------------------------------------------------------------------
// Public API for the C ABI (blocking, with timeout)
// ---------------------------------------------------------------------------

/// How long a caller waits for an answer. Must cover the worst case of
/// run_query (REQ_TIMEOUT + CONNECT_TIMEOUT + REQ_TIMEOUT = 26 s plus the time
/// of the query itself), otherwise the answer of a successful second attempt
/// would never arrive.
const QUERY_TIMEOUT: Duration = Duration::from_secs(40);

/// Waits for an engine answer and calls `pump` in between (every ~40 ms).
/// The C ABI passes a no-op: Klangten calls these functions from a worker
/// thread. Pumping matters only for a caller that blocks its GUI thread: on
/// Windows a window that pumps no messages for ~5 s counts as "Not
/// responding" — it gets ghosted and the user is offered to end the program,
/// and library/playlist queries can block for many seconds.
fn recv_pumped<T>(
    rrx: &std::sync::mpsc::Receiver<T>,
    timeout: Duration,
    pump: &mut dyn FnMut(),
) -> Option<T> {
    let start = std::time::Instant::now();
    loop {
        match rrx.recv_timeout(Duration::from_millis(40)) {
            Ok(v) => return Some(v),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if start.elapsed() >= timeout {
                    return None;
                }
                pump();
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return None,
        }
    }
}

/// Starts a login (fire-and-forget) and returns the current status.
pub fn login() -> String {
    let e = engine();
    let _ = e.tx.send(Cmd::Login);
    status()
}

pub fn status() -> String {
    engine().shared.login.lock().unwrap().as_str().to_string()
}

pub fn logout() {
    let _ = engine().tx.send(Cmd::Logout);
}

fn query_tracks(
    cmd_builder: impl FnOnce(std::sync::mpsc::Sender<Vec<TrackInfo>>) -> Cmd,
    pump: &mut dyn FnMut(),
) -> Vec<TrackInfo> {
    let (rtx, rrx) = std::sync::mpsc::channel();
    let _ = engine().tx.send(cmd_builder(rtx));
    recv_pumped(&rrx, QUERY_TIMEOUT, pump).unwrap_or_default()
}

pub fn search(query: &str, limit: usize, pump: &mut dyn FnMut()) -> Vec<TrackInfo> {
    let q = query.to_string();
    query_tracks(|reply| Cmd::Search { query: q, limit, reply }, pump)
}

/// Recommendations for a track ("song radio") — the list the host keeps
/// playing from when a SINGLE search hit is started.
pub fn track_radio_pub(uri: &str, limit: usize, pump: &mut dyn FnMut()) -> Vec<TrackInfo> {
    let u = uri.to_string();
    query_tracks(|reply| Cmd::TrackRadio { uri: u, limit, reply }, pump)
}

pub fn search_typed_pub(query: &str, limit: usize, pump: &mut dyn FnMut()) -> Vec<SearchRow> {
    let (rtx, rrx) = std::sync::mpsc::channel();
    let _ = engine().tx.send(Cmd::SearchTyped {
        query: query.to_string(),
        limit,
        reply: rtx,
    });
    recv_pumped(&rrx, QUERY_TIMEOUT, pump).unwrap_or_default()
}

pub fn show_pub(uri: &str, limit: usize, pump: &mut dyn FnMut()) -> Option<AlbumDetails> {
    let (rtx, rrx) = std::sync::mpsc::channel();
    let _ = engine().tx.send(Cmd::Show { uri: uri.to_string(), limit, reply: rtx });
    recv_pumped(&rrx, QUERY_TIMEOUT, pump).flatten()
}

pub fn artist_pub(uri: &str, limit: usize, pump: &mut dyn FnMut()) -> Option<ArtistDetails> {
    let (rtx, rrx) = std::sync::mpsc::channel();
    let _ = engine().tx.send(Cmd::Artist { uri: uri.to_string(), limit, reply: rtx });
    recv_pumped(&rrx, QUERY_TIMEOUT, pump).flatten()
}

pub fn album_pub(uri: &str, limit: usize, pump: &mut dyn FnMut()) -> Option<AlbumDetails> {
    let (rtx, rrx) = std::sync::mpsc::channel();
    let _ = engine().tx.send(Cmd::Album { uri: uri.to_string(), limit, reply: rtx });
    recv_pumped(&rrx, QUERY_TIMEOUT, pump).flatten()
}

pub fn library(limit: usize, pump: &mut dyn FnMut()) -> Vec<TrackInfo> {
    query_tracks(|reply| Cmd::Library { limit, reply }, pump)
}

pub fn playlist_tracks_pub(uri: &str, limit: usize, pump: &mut dyn FnMut()) -> Vec<TrackInfo> {
    let u = uri.to_string();
    query_tracks(|reply| Cmd::PlaylistTracks { uri: u, limit, reply }, pump)
}

pub fn playlists(limit: usize, pump: &mut dyn FnMut()) -> Vec<PlaylistInfo> {
    let (rtx, rrx) = std::sync::mpsc::channel();
    let _ = engine().tx.send(Cmd::Playlists { limit, reply: rtx });
    recv_pumped(&rrx, QUERY_TIMEOUT, pump).unwrap_or_default()
}

/// Opens a track; returns the PCM feed (ks_open wraps it in a stream handle).
pub fn open(uri: &str, start_ms: u32, pump: &mut dyn FnMut()) -> Option<Arc<PcmFeed>> {
    let (rtx, rrx) = std::sync::mpsc::channel();
    let _ = engine().tx.send(Cmd::Open {
        start_ms,
        uri: uri.to_string(),
        reply: rtx,
    });
    recv_pumped(&rrx, QUERY_TIMEOUT, pump).flatten()
}

pub fn control(action: &str, arg: i64) {
    let _ = engine().tx.send(Cmd::Control {
        action: action.to_string(),
        arg,
    });
}

pub fn now_playing() -> NowPlaying {
    let shared = &engine().shared;
    let mut n = shared.now.lock().unwrap().clone();
    // Towards the outside the AUDIBLE position counts, not librespot's decode
    // position. While a seek is in progress, now.position_ms already holds
    // the (optimistic) target — that is the better answer then.
    if !seeking(shared) {
        n.position_ms = audible_position_ms(shared);
    }
    n
}


#[cfg(test)]
mod tests {
    use super::search_context_uri;

    /// First contact with the engine without a login: reading the status
    /// builds the singleton including the tokio runtime; queries without a
    /// session come back empty instead of crashing.
    #[test]
    fn engine_bringup_ohne_login() {
        let _ = super::CACHE_DIR.set(std::env::temp_dir().join("klangten_spotify_test_cache"));
        let s = super::status();
        assert!(s == "loggedout" || s == "failed", "status={}", s);
        assert!(super::search("kraftwerk", 3, &mut || {}).is_empty());
        assert!(super::playlists(5, &mut || {}).is_empty());
        assert!(super::open("spotify:track:2TpxZ7JUBn3uw46aR7qd6V", 0, &mut || {}).is_none());
        super::control("stop", 0);
        assert_eq!(super::now_playing().state, "");
    }

    /// REAL end-to-end test (network + stored login, hence #[ignore]):
    /// KLANGTEN_SPOTIFY_TEST_CACHE = directory with credentials.json.
    #[test]
    #[ignore]
    fn e2e_login_suche_wiedergabe() {
        let dir = std::env::var("KLANGTEN_SPOTIFY_TEST_CACHE")
            .expect("set KLANGTEN_SPOTIFY_TEST_CACHE to a cache dir with credentials.json");
        let _ = super::CACHE_DIR.set(std::path::PathBuf::from(&dir));
        // The library no longer reads credentials from disk; the test hands
        // them in the way Klangten does.
        let json = std::fs::read_to_string(std::path::Path::new(&dir).join("credentials.json"))
            .expect("credentials.json in KLANGTEN_SPOTIFY_TEST_CACHE");
        assert!(super::set_stored_credentials(&json), "credentials.json unreadable");
        super::login();
        let mut s = String::new();
        for _ in 0..600 {
            s = super::status();
            if s == "ok" || s == "failed" || s == "nopremium" {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert_eq!(s, "ok", "login status: {}", s);
        let tracks = super::search("kraftwerk", 5, &mut || {});
        assert!(!tracks.is_empty(), "search returned nothing");
        let feed = super::open(&tracks[0].uri, 0, &mut || {}).expect("open returned nothing");
        // Like the host: read regularly and count frames.
        let mut buf = vec![0f32; 8192];
        let mut total = 0i64;
        for _ in 0..300 {
            let n = feed.read_into(&mut buf);
            if n > 0 {
                total += n;
            }
            if total >= 44100 * 5 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert!(total >= 44100, "no PCM arrived (state={})", feed.state());
        super::control("seekrel", 30_000);
        let mut after = 0i64;
        for _ in 0..200 {
            let n = feed.read_into(&mut buf);
            if n > 0 {
                after += n;
            }
            if after >= 44100 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        assert!(after >= 44100, "no more PCM after seeking (gate={})", feed.is_gated());
        super::control("stop", 0);
    }

    #[test]
    fn suchkontext_uri() {
        assert_eq!(search_context_uri("hello world"), "spotify:search:hello+world");
        assert_eq!(search_context_uri("kraftwerk"), "spotify:search:kraftwerk");
        assert_eq!(search_context_uri("björk"), "spotify:search:bj%C3%B6rk");
    }
}
