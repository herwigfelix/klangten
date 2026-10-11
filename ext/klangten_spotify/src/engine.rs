// engine.rs — Spotify-Wiedergabe über librespot (nativer Rust-Client) für
// Klango 4. DESTILLAT aus klango_rs/src/engine/spotify.rs (Klango 3): die
// Logik ist 1:1 übernommen — Session + Player auf einem eigenen tokio-Thread,
// Browser-OAuth fire-and-forget mit Status-Polling, Credential-Cache,
// Wiederaufnahme nach Netzfehlern (resume_point/retire/trouble), Suche,
// Song-Radio, Hörbuch/Künstler/Album/Playlist/Mediathek, open(uri,start_ms),
// control(action,arg), now_playing. Ersetzt ist nur, was an Klango 3 hing:
//
//   * statt der mlua-Globals k_Spotify* gibt es eine C-ABI (src/ffi.rs), die
//     Klango 4 per ctypes lädt (klango4/src/klango4/engine/spotify.py);
//   * statt Klango-3-IcyFeed (i16) schreibt der Sink in einen eigenen
//     Ringpuffer (src/feed.rs, f32 — das Format des Klango-4-Mischers), aus
//     dem Python mit ks_read_pcm zieht.
//
// Ursprünglicher Kopf (Klango 3):
//
// > engine/spotify.rs — Spotify-Wiedergabe über librespot (nativer Rust-Client).
// >
// > Anders als ein installierbares Programm ist Spotify FEST in Klango eingebaut
// > und unter „Dateien" erreichbar (llib_spotify.lua → app:modalDialog{type=
// > "tree"}). librespot erledigt Login (OAuth), Suche, eigene Mediathek und
// > Playlists über EIN Login (spclient, kein separates Web-API-Token) und
// > dekodiert Ogg/Vorbis zu PCM. Ein eigener librespot-Sink schiebt dieses PCM
// > in denselben Mixer-Feed (PcmFeed) wie das Internetradio — Spotify läuft
// > damit durch Klangos komplette 3D-/Ducking-/Mitschnitt-Pipeline.
// >
// > Nebenläufigkeit: librespot ist async. EINE tokio-Runtime läuft auf einem
// > eigenen OS-Thread und besitzt Session + Player. Die Lua-Globals (k_Spotify*)
// > schicken Kommandos über einen Kanal; kurze Abfragen (Suche/Mediathek) warten
// > synchron auf die Antwort — wie der KRPC-Client des Klango-Speichers, der
// > seine Netz-Aufrufe ebenfalls blockierend macht. Der Login läuft dagegen
// > fire-and-forget (Browser-OAuth kann lange dauern); Lua pollt k_SpotifyStatus.
// > Der geteilte Zustand (Login/Now-Playing) liegt in Arc<Mutex> und wird direkt
// > gelesen, ohne den Kanal zu bemühen.
// >
// > Premium: librespot streamt NUR mit Spotify Premium. Der Login gelingt auch
// > mit Gratis-Konten, aber die Wiedergabe scheitert dann (PlayerEvent::
// > Unavailable) → Zustand "unavailable", der Client sagt „Premium erforderlich".

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

// Die librespot-Client-ID (dieselbe, die librespot intern nutzt).
const SPOTIFY_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const OAUTH_REDIRECT: &str = "http://127.0.0.1:5588/login";
const OAUTH_SCOPES: &[&str] = &[
    "streaming",
    "user-read-playback-state",
    "user-read-currently-playing",
    "playlist-read-private",
    "user-library-read",
];

/// Spotify liefert 44100 Hz Stereo; der Sink reicht f64 als interleaved f32
/// weiter (Klango-4-Mischer rechnet in float32, ebenfalls 44100 Hz).
const SR: u32 = 44100;
const CH: u32 = 2;

/// Cache-Verzeichnis (~/.klango/spotify_cache) — in main.rs gesetzt.
pub static CACHE_DIR: OnceLock<PathBuf> = OnceLock::new();

// ---- Zeitgrenzen der Verbindung (s. "Verbindung: aufbauen, pruefen, neu
// aufbauen" weiter unten) ----

/// Eine einzelne Netzanfrage (Kontext, Metadaten, Suche, Token) hoechstens so
/// lange. librespots HTTP-Client kennt KEINE Zeitgrenze: eine Anfrage ueber
/// eine halbtote Verbindung (Ruhezustand, verfallener NAT-Eintrag) hing bis
/// zum TCP-Timeout des Systems, also Minuten. Weil der Engine-Thread die
/// Kommandos der Reihe nach abarbeitet, hing damit JEDE weitere Spotify-
/// Anfrage mit — das war "nach laengerem Leerlauf laeuft die Suche ins
/// Timeout, und die Verbindung kommt nicht wieder".
const REQ_TIMEOUT: Duration = Duration::from_secs(8);
/// Verbindungsaufbau (Access Point suchen, verbinden, anmelden).
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Kam so lange (Wanduhr) kein Paket vom Access Point, gilt die Verbindung als
/// tot: der Server schickt spaetestens alle 60 s ein Ping bzw. PongAck.
const STALE_AFTER_MS: u64 = 100_000;
/// Browser-Anmeldung: danach gibt der Engine-Thread auf, statt fuer immer zu
/// warten (solange er wartet, bleibt jedes andere Spotify-Kommando liegen).
const OAUTH_TIMEOUT: Duration = Duration::from_secs(300);

// ---------------------------------------------------------------------------
// Geteilter Zustand (Lua liest ihn direkt, ohne Kommando)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub enum LoginState {
    LoggedOut,
    LoggingIn,
    LoggedIn,
    /// Anmeldung gelang, aber das Konto hat kein Premium. Ein EIGENER Zustand,
    /// kein Failed: der Nutzer hat nichts falsch gemacht, und Klango muss ihm
    /// etwas anderes sagen als "Anmeldung fehlgeschlagen".
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
    /// Ziel-Feed des Sinks — beim Öffnen eines neuen Titels ausgetauscht.
    current_feed: Mutex<Option<Arc<PcmFeed>>>,
    /// Laufendes Spulen: Zielposition in ms. Solange gesetzt, ist ein Seek
    /// „in Arbeit". librespot meldet danach noch kurz die ALTE Position
    /// (Events laufen asynchron nach) — die würde die relative Spul-Basis
    /// verfälschen (links spulte dann vor) und ein Seek-EndOfTrack den Titel
    /// fälschlich weiterschalten. Solange seek_target gesetzt ist, ignorieren
    /// wir verspätete Positions-/Ende-Events, bis ein Event die Zielposition
    /// bestätigt (dann gilt der Seek als erledigt).
    seek_target: Mutex<Option<u32>>,
    /// Basis der HÖRBAREN Position: Position beim Titelstart (0) bzw. beim
    /// letzten bestätigten Seek. Hörbar = Basis + vom Mixer seither gespielte
    /// Frames (feed.played_frames). librespots Event-Position ist dagegen die
    /// DEKODIER-Position, die dem Hörbaren um den Puffer-Vorlauf vorauseilt —
    /// als Spul-Basis wäre sie falsch (links spulte dann vor).
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

/// Ein Titel für Trefferlisten (Suche/Mediathek/Playlist).
#[derive(Clone, Debug)]
pub struct TrackInfo {
    pub uri: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    /// URIs zu Kuenstler und Album des Titels. librespot kann NUR nach Titeln
    /// suchen (alle anderen Sucharten sind ueber den spclient nicht zu haben,
    /// nachgeprueft 2026-08-28). Klango leitet "Kuenstler" und "Alben" deshalb
    /// aus den Titeltreffern ab — dafuer braucht die Lua-Ebene diese beiden
    /// Kennungen.
    pub artist_uri: String,
    pub album_uri: String,
}

/// Name + URI — fuer Alben, Kuenstler und aehnliche Kuenstler.
#[derive(Clone, Debug, Default)]
pub struct NamedItem {
    pub uri: String,
    pub name: String,
}

/// Eine Kuenstlerseite: alles, was das Formular in Klango zeigt.
#[derive(Clone, Debug, Default)]
pub struct ArtistDetails {
    pub uri: String,
    pub name: String,
    pub biography: String,
    pub top: Vec<TrackInfo>,
    pub albums: Vec<NamedItem>,
    pub related: Vec<NamedItem>,
}

/// Ein Album mit seinen Titeln.
#[derive(Clone, Debug, Default)]
pub struct AlbumDetails {
    pub uri: String,
    pub name: String,
    pub artist: String,
    pub tracks: Vec<TrackInfo>,
}

/// Eine Playlist des Nutzers.
#[derive(Clone, Debug)]
pub struct PlaylistInfo {
    pub uri: String,
    pub name: String,
}

// ---------------------------------------------------------------------------
// Kommandos an den Engine-Thread
// ---------------------------------------------------------------------------

enum Cmd {
    /// Anmelden (fire-and-forget; Lua pollt den Login-Zustand).
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
    /// Empfehlungen zu einem Titel ("Song-Radio").
    TrackRadio {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<TrackInfo>>,
    },
    /// Typisierte Suche (Titel, Kuenstler, Alben, Playlists, Hoerbuecher,
    /// Podcasts) ueber pathfinder.
    SearchTyped {
        query: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Vec<SearchRow>>,
    },
    /// Hoerbuch/Podcast mit Kapiteln bzw. Folgen.
    Show {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Option<AlbumDetails>>,
    },
    /// Kuenstlerseite (Top-Titel, Alben, aehnliche Kuenstler, Biografie).
    Artist {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Option<ArtistDetails>>,
    },
    /// Album mit seinen Titeln.
    Album {
        uri: String,
        limit: usize,
        reply: std::sync::mpsc::Sender<Option<AlbumDetails>>,
    },
    /// Titel öffnen: neuen Feed erzeugen, laden, Feed zurückgeben.
    /// `start_ms` > 0 setzt dort ein — so laeuft ein Hoerbuch an der Stelle
    /// weiter, an der man es verlassen hat.
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
// librespot-Sink → Mixer-Feed
// ---------------------------------------------------------------------------

/// Schiebt librespots dekodiertes PCM in den jeweils aktuellen Feed. Der Feed
/// wird beim Öffnen eines neuen Titels ausgetauscht (Arc<Mutex<Option<…>>>),
/// der Sink bleibt derselbe (Player wird nur einmal gebaut).
struct FeedSink {
    slot: Arc<Mutex<Option<Arc<PcmFeed>>>>,
}

impl Open for FeedSink {
    fn open(_device: Option<String>, _format: AudioFormat) -> Self {
        // Wird nie aufgerufen — der Player baut den Sink über die Closure mit
        // echtem Slot. Fallback: leerer Slot (write verwirft dann still).
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
                // Klango 3 wandelte hier nach i16 (converter.f64_to_s16) —
                // Klango 4 mischt in float32, also ohne Umweg. Die
                // Normalisierung hat der Player schon vorher angewandt.
                let _ = &converter;
                let pcm: Vec<f32> = samples.iter().map(|&x| x as f32).collect();
                // Nur in den AKTUELLEN Feed schieben; nach einem Umschalten
                // ist der alte Feed abgebrochen und wird ignoriert.
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
                "Raw-Passthrough wird nicht unterstützt".into(),
            )),
        }
    }
}

// ---------------------------------------------------------------------------
// Engine (globales Singleton)
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
                    crate::klog!("[spotify] tokio-Runtime fehlgeschlagen: {}", e);
                    shared_thread.set_login(LoginState::Failed("runtime".into()));
                    return;
                }
            };
            rt.block_on(engine_loop(rx, shared_thread));
        })
        .expect("spotify-thread");
    SpotifyEngine { tx, shared }
}

/// Player-Events laufen in einem EIGENEN Task (nicht im select des Kommando-
/// loops) — das entkoppelt sie sauber und vermeidet doppelte &mut-Ausleihen
/// von `events`. Der Task endet, wenn der Player fällt (Kanal schließt).
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

/// Gehört dieses Event zum GERADE geladenen Titel? Beim Umschalten feuert
/// librespot für den ALTEN Titel noch Stopped/EndOfTrack — würde man das blind
/// auf shared.current_feed (schon der NEUE Feed!) anwenden, gälte der neue
/// Titel sofort als „fertig" und der Player sprang endlos weiter. Darum jedes
/// Ende-/Fehler-Event an der Track-URI festmachen.
fn is_current(track_id: &SpotifyUri, shared: &Arc<Shared>) -> bool {
    match track_id.to_uri() {
        Ok(u) => u == shared.now.lock().unwrap().uri,
        Err(_) => false,
    }
}

/// Seek abschließen: Ziel löschen, Spul-Tor öffnen (der Mixer spielt wieder
/// den Feed statt Stille) und die echte Position übernehmen.
fn finish_seek(shared: &Arc<Shared>, position_ms: u32) {
    *shared.seek_target.lock().unwrap() = None;
    // Neue Hörbar-Basis: ab hier zählt der Mixer wieder gespielte Frames.
    // Zähler VOR dem Tor-Öffnen nullen, sonst zählten Alt-Frames mit.
    *shared.audible_base_ms.lock().unwrap() = position_ms;
    if let Some(feed) = shared.current_feed.lock().unwrap().as_ref() {
        feed.reset_played();
        feed.set_gate(false);
    }
    shared.now.lock().unwrap().position_ms = position_ms;
}

/// HÖRBARE Position: Basis (Titelstart/letzter Seek) + vom Mixer seither
/// gespielte Frames. Fallback (kein Feed/Format): librespots Event-Position.
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

/// Position aus einem librespot-Event übernehmen — aber während eines
/// laufenden Seeks die noch verspätet gemeldete ALTE Position ignorieren, bis
/// ein Event die Zielposition (± Toleranz) bestätigt (Fallback, falls das
/// Seeked-Event ausbleibt). Dann gilt der Seek als erledigt.
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
            // Autoritatives Seek-Ende: Tor auf, echte Position übernehmen.
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
            // NUR Ende des laufenden Titels — nicht das Stop-Echo eines
            // vorherigen Titels (is_current). Lief noch ein Seek, hat das
            // Titelende ihn überholt: der Player ist schon gestoppt, ein
            // Seeked kommt nie mehr — den Seek abschließen, sonst bleibt das
            // Spul-Tor für immer zu (Dauer-Stille statt Titelwechsel).
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
            // Titel nicht abspielbar — häufigster Grund: kein Premium.
            if is_current(&track_id, shared) && !seeking(shared) {
                if let Some(feed) = shared.current_feed.lock().unwrap().as_ref() {
                    feed.set_state_ext("unavailable");
                    feed.cancel();
                    feed.mark_done();
                }
                shared.set_state("unavailable");
            }
        }
        // Stopped feuert beim Umschalten/Laden (für den ALTEN Titel) — der Feed
        // wird beim expliziten Stop ohnehin in Lua/Control aufgeräumt. Hier
        // bewusst ignorieren, sonst gilt der neue Titel sofort als gestoppt.
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
            // Ausdruecklicher Login: nur HIER darf ein Browser aufgehen.
            match reconnect(conn, shared, true, Resume::Keep).await {
                Ok(()) => {}
                Err(e) if e == NO_PREMIUM => {
                    crate::klog!("[spotify] Konto ohne Premium — keine Wiedergabe.");
                }
                Err(e) => {
                    crate::klog!("[spotify] Login fehlgeschlagen: {}", e);
                    shared.set_login(LoginState::Failed(e));
                }
            }
        }
        Cmd::Logout => {
            retire(conn);
            *shared.current_feed.lock().unwrap() = None;
            *shared.now.lock().unwrap() = NowPlaying::default();
            shared.set_login(LoginState::LoggedOut);
            // Zwischengespeicherte Credentials löschen, damit der nächste Login
            // wirklich neu anmeldet.
            forget_credentials();
        }
        Cmd::Search { query, limit, reply } => {
            let out = run_query(conn, shared, "Suche", |s: Session| {
                let q = &query;
                async move { search_tracks(&s, q, limit).await }
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::Library { limit, reply } => {
            let out = run_query(conn, shared, "Mediathek", |s: Session| async move {
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
            let out = run_query(conn, shared, "Playlist-Titel", |s: Session| {
                let u = &uri;
                async move { playlist_tracks(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::TrackRadio { uri, limit, reply } => {
            let out = run_query(conn, shared, "Song-Radio", |s: Session| {
                let u = &uri;
                async move { track_radio(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out.unwrap_or_default());
        }
        Cmd::SearchTyped { query, limit, reply } => {
            let out = run_query(conn, shared, "Suche", |s: Session| {
                let q = &query;
                async move {
                    match search_typed(&s, q, limit).await {
                        Some(rows) => Some(rows),
                        // pathfinder nicht erreichbar (Abfrage-Hash veraltet?):
                        // wenigstens die Titel ueber den Kontextweg liefern.
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
            let out = run_query(conn, shared, "Hoerbuch/Podcast", |s: Session| {
                let u = &uri;
                async move { show_details(&s, u, limit).await }
            })
            .await;
            let _ = reply.send(out);
        }
        Cmd::Artist { uri, limit, reply } => {
            let out = run_query(conn, shared, "Kuenstler", |s: Session| {
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
            // Der alte Titel wird ohnehin ersetzt — nichts fortsetzen.
            if let Err(e) = ensure_live(conn, shared, Resume::Drop).await {
                crate::klog!("[spotify] Titel oeffnen: {}", e);
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
                // Relatives Spulen (Pfeil links/rechts im Klango-Player):
                // arg = Verschiebung in ms (±). Der Mixer-Feed selbst ist
                // nicht spulbar (Live-Strom) — deshalb rechnet die Engine
                // aus der aktuellen Position eine neue absolute Position und
                // lässt librespot dorthin springen.
                //
                // Titel schon fertig dekodiert (librespot intern
                // gestoppt)? Dann wäre p.seek ein No-Op — es käme nie
                // ein Seeked, das Tor bliebe zu und der Titel hinge in
                // Dauer-Stille. Spulen im Auslauf-Rest still ignorieren;
                // das natürliche Ende (Titelwechsel) kommt gleich.
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
                // Basis ist das laufende Seek-Ziel (falls gerade gespult
                // wird), sonst die HÖRBARE Position — librespots Event-
                // Position ist die Dekodier-Position und eilt dem Ohr
                // um den Puffer-Vorlauf voraus (links spulte dann vor).
                // So addieren sich schnelle Tastendrücke verlässlich
                // auf, ohne von verspäteten Events verfälscht zu werden.
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
                // Nie GANZ ans Ende springen: ein Seek auf die letzte
                // Sekunde stoppt librespot sofort (EndOfTrack statt
                // Seeked) — kurz davor landen und normal auslaufen.
                if dur > 2000 && np > dur - 2000 {
                    np = dur - 2000;
                } else if dur > 0 && np > dur {
                    np = dur;
                }
                let np = np as u32;

                // Verbindung tot? Dann braucht der Sprung Audiodaten, die
                // ueber die alte Sitzung nie mehr kommen. Statt p.seek neu
                // verbinden und den Titel gleich an der Zielstelle neu laden.
                if !conn.alive() && has_cached_credentials() {
                    reset_trouble();
                    if let Ok(true) = ensure_live(conn, shared, Resume::At(np)).await {
                        return;
                    }
                    // Neuaufbau gescheitert: mit dem alten Player versuchen.
                }

                *shared.seek_target.lock().unwrap() = Some(np);
                shared.now.lock().unwrap().position_ms = np; // optimistisch anzeigen
                // Tor ZU + Ring leeren VOR dem Seek: ab jetzt verwirft der
                // Mixer den (noch alten) Feed-Nachschub, bis librespot den
                // Sprung bestätigt — kein Vorwärts-Klang beim Rückspulen.
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

/// Kennzeichen fuer "Konto ohne Premium" auf dem Fehlerweg von
/// `connect_session`. Ein eigener Fehlertext waere uebersetzbar und damit
/// unzuverlaessig zu vergleichen; diese Zeichenkette ist ein Schluessel.
const NO_PREMIUM: &str = "nopremium";
/// Keine gespeicherten Anmeldedaten (und kein Browser erlaubt).
const NOT_LOGGED_IN: &str = "notloggedin";
/// Spotify hat die gespeicherten Anmeldedaten abgelehnt.
const REJECTED: &str = "rejected";

/// Die gespeicherten Anmeldedaten wegräumen.
fn forget_credentials() {
    let had = CREDENTIALS.lock().unwrap().take().is_some();
    if had {
        CREDENTIALS_SERIAL.fetch_add(1, Ordering::SeqCst);
    }
}

// ---------------------------------------------------------------------------
// Stored credentials (Klangten)
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

/// Wartet kurz darauf, dass Spotify die Kontoart meldet.
///
/// Die Produktinformation kommt als eigenes Paket, kurz NACH dem Anmelden —
/// direkt hinter `connect` steht sie noch nicht fest. Wir warten hoechstens
/// ein paar Sekunden; bleibt die Auskunft aus, gilt das Konto als brauchbar
/// (lieber einmal zu viel abspielen als eine gueltige Anmeldung abweisen).
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

/// True, wenn librespot gespeicherte Anmeldedaten hat (stiller Login möglich).
pub fn has_cached_credentials() -> bool {
    CREDENTIALS.lock().unwrap().is_some()
}

// ---------------------------------------------------------------------------
// Verbindung: aufbauen, pruefen, neu aufbauen
// ---------------------------------------------------------------------------
//
// Spotify trennt die Verbindung nach laengerem Leerlauf, bei Netzwechseln und
// im Ruhezustand des Rechners. librespot verbindet NICHT von selbst neu; es
// erklaert die Session hoechstens fuer ungueltig — und auch das erst, wenn
// sein Keep-Alive-Timer ablaeuft. Der laeuft auf dem monotonen Takt, der auf
// macOS im Ruhezustand stillsteht: nach dem Aufwachen galt eine tote Sitzung
// noch minutenlang als gesund, und librespots HTTP-Anfragen (ohne jede
// Zeitgrenze) hingen auf toten Verbindungen.
//
// Darum gilt bei JEDEM Zugriff:
//   1. ensure_live: Session ungueltig ODER seit STALE_AFTER_MS (Wanduhr) kein
//      Paket vom Access Point → still neu verbinden (gespeicherte
//      Anmeldedaten, nie ein Browser).
//   2. Jede einzelne Anfrage hat eine Zeitgrenze (REQ_TIMEOUT, `net`).
//   3. Scheitert ein Aufruf trotzdem an einem NETZfehler, wird einmal neu
//      verbunden und wiederholt (`run_query`).
// Ein Neuaufbau baut auch den Player neu (er haengt an seiner Session) und
// setzt einen laufenden Titel an der hoerbaren Stelle im SELBEN Feed fort —
// Klangos Mixer-Instanz merkt davon nur eine kurze Luecke.

/// Session + Player. Der Player haengt an genau dieser Session.
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

/// Hat der laufende Versuch eines Kommandos ein NETZproblem gesehen
/// (Zeitueberschreitung, Verbindungsfehler, abgelaufenes Token)? Nur dann
/// lohnt Neuverbinden + Wiederholen — ein schlicht nicht gefundenes Album soll
/// die laufende Musik nicht unterbrechen. Global, weil die Metadaten in
/// eigenen tokio-Tasks laufen; die Engine arbeitet ohnehin ein Kommando nach
/// dem anderen ab. Zugleich die Notbremse: ist es gesetzt, gehen weitere
/// Anfragen gar nicht erst raus (sonst wartete eine Liste von 100 Titeln
/// 100 Mal REQ_TIMEOUT ab).
static NET_TROUBLE: AtomicBool = AtomicBool::new(false);

fn reset_trouble() {
    NET_TROUBLE.store(false, Ordering::SeqCst);
}

fn trouble() -> bool {
    NET_TROUBLE.load(Ordering::SeqCst)
}

fn note_trouble(what: &str) {
    if !NET_TROUBLE.swap(true, Ordering::SeqCst) {
        crate::klog!("[spotify] Netzproblem: {}", what);
    }
}

/// Fehlerarten, hinter denen eine kaputte Verbindung stecken kann (im
/// Gegensatz zu "nicht gefunden", "nicht erlaubt", "unlesbar").
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

/// Eine librespot-Anfrage mit Zeitgrenze. Netzfehler und Zeitueberschreitung
/// merkt sich NET_TROUBLE; andere Fehler (nicht gefunden …) nicht.
async fn net<T>(
    what: &str,
    fut: impl std::future::Future<Output = Result<T, librespot_core::Error>>,
) -> Option<T> {
    if trouble() {
        return None; // Verbindung schon als kaputt erkannt: nicht noch warten
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
                "{}: keine Antwort nach {} s",
                what,
                REQ_TIMEOUT.as_secs()
            ));
            None
        }
    }
}

/// Was nach einem Neuaufbau mit dem laufenden Titel geschieht.
enum Resume {
    /// An der hoerbaren Stelle fortsetzen.
    Keep,
    /// An dieser Stelle (ms) fortsetzen — Spulen ueber eine tote Verbindung.
    At(u32),
    /// Nicht fortsetzen (gleich kommt ohnehin ein anderer Titel).
    Drop,
}

struct ResumePoint {
    uri: String,
    pos: u32,
    play: bool,
    feed: Arc<PcmFeed>,
}

/// Laeuft gerade ein Titel, der nach einem Neuaufbau weiterlaufen soll?
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

/// Den Titel auf dem NEUEN Player an `rp.pos` fortsetzen — in denselben Feed,
/// den Klangos Mixer gerade spielt. Laeuft ueber die Spul-Mechanik: Tor zu,
/// bis librespot die Zielposition meldet (finish_seek), so dass kein Rest des
/// alten Players hoerbar wird.
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
        "[spotify] setze {} bei {} s fort",
        rp.uri,
        rp.pos / 1000
    );
    player.load(uri, rp.play, rp.pos);
}

/// Alte Session + Player abraeumen, OHNE den Engine-Thread zu blockieren.
///
/// `Player::drop` wartet (join) auf den Player-Thread. Der kann in
/// FeedSink::write stecken — der Ring ist voll, weil Klangos Mixer den Titel
/// angehalten hat — und kaeme dann nie frei. Im async-Kontext hielte das den
/// ganzen Engine-Thread fest: keine Suche, kein Titel, nichts mehr. Darum
/// fallen gelassen wird auf einem Wegwerf-Thread; der alte Sink bekommt
/// vorher seinen Slot entzogen und verwirft alles Weitere.
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

/// Stellt vor jeder Anfrage/Wiedergabe sicher, dass die Session LEBT; baut sie
/// sonst still aus den gespeicherten Anmeldedaten neu auf (nie ein Browser:
/// eine Hintergrundanfrage darf keinen oeffnen). Ok(true) = neu verbunden.
async fn ensure_live(conn: &mut Conn, shared: &Arc<Shared>, resume: Resume) -> Result<bool, String> {
    if conn.alive() {
        return Ok(false);
    }
    match conn.session.as_ref() {
        Some(s) if s.is_invalid() => {
            crate::klog!("[spotify] Session von librespot beendet — verbinde neu…");
        }
        Some(s) => {
            crate::klog!(
                "[spotify] seit {} s kein Lebenszeichen vom Access Point — verbinde neu…",
                s.millis_since_last_packet() / 1000
            );
        }
        None => {}
    }
    if !has_cached_credentials() {
        return Err("nicht bei Spotify angemeldet".to_string());
    }
    reconnect(conn, shared, false, resume).await.map(|_| true)
}

/// Neue Session aufbauen und ERST DANN die alte ersetzen ("make before
/// break"): klappt der Neuaufbau nicht (Netz noch weg), bleibt alles, wie es
/// war — ein Titel, der aus dem Puffer weiterspielt, wird nicht abgewuergt.
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
                // Anmeldedaten ungueltig: Klango soll beim naechsten Oeffnen
                // wieder anmelden (dann mit Browser).
                shared.set_login(LoginState::Failed(e.clone()));
            }
            // Netzfehler: Zustand bleibt; der naechste Zugriff versucht es neu.
            return Err(e);
        }
    };
    // Stelle des laufenden Titels erst JETZT nehmen — der Aufbau hat gedauert.
    let rp = match resume {
        Resume::Keep => resume_point(shared, None),
        Resume::At(ms) => resume_point(shared, Some(ms)),
        Resume::Drop => None,
    };
    retire(conn);
    install_player(conn, shared, sess);
    shared.set_login(LoginState::LoggedIn);
    crate::klog!("[spotify] verbunden");
    if let Some(rp) = rp {
        resume_track(conn, shared, rp);
    }
    Ok(())
}

/// Eine Session verbinden: gespeicherte Anmeldedaten, sonst (nur wenn
/// `interactive`) OAuth im Browser. Mit Zeitgrenze, damit ein totes Netz den
/// Engine-Thread nicht festhaelt.
async fn connect_session(interactive: bool) -> Result<Session, String> {
    // Klangten: no credentials and no audio files on disk - the cache keeps
    // only librespot's volume file. Credentials come from the host
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
    // Vor JEDEM Versuch zuruecksetzen: das Merkmal ist global und ueberlebt
    // sonst einen Kontowechsel.
    librespot_core::session::reset_non_premium();
    match tokio::time::timeout(CONNECT_TIMEOUT, sess.connect(credentials, true)).await {
        Ok(Ok(())) => {}
        // Zwischengespeicherte Credentials abgelehnt → einmal per OAuth neu —
        // aber NUR beim ausdruecklichen Login. Ein Netzfehler ist KEIN Grund
        // fuer den Browser (frueher oeffnete ihn jeder gescheiterte Neuaufbau,
        // und der Engine-Thread wartete dann ewig auf die Anmeldung).
        Ok(Err(e)) if e.kind == ErrorKind::PermissionDenied => {
            if !interactive {
                crate::klog!("[spotify] gespeicherte Anmeldung abgelehnt: {e}");
                return Err(REJECTED.to_string());
            }
            crate::klog!("[spotify] Verbindung mit Cache-Credentials scheiterte: {e}. OAuth…");
            let fresh = oauth_login().await?;
            match tokio::time::timeout(CONNECT_TIMEOUT, sess.connect(fresh, true)).await {
                Ok(Ok(())) => {}
                Ok(Err(e)) => return Err(format!("Verbindung: {}", e)),
                Err(_) => return Err("Verbindung: Zeitueberschreitung".to_string()),
            }
        }
        Ok(Err(e)) => return Err(format!("Verbindung: {}", e)),
        Err(_) => {
            return Err(format!(
                "Verbindung: keine Antwort nach {} s",
                CONNECT_TIMEOUT.as_secs()
            ))
        }
    }

    // Ohne Premium liefert Spotify keine Audiodaten — librespot kann damit
    // nichts anfangen und beendete im Original an dieser Stelle den ganzen
    // Prozess (siehe vendor/librespot-core). Wir hoeren stattdessen hier auf,
    // und zwar BEVOR ein Player entsteht.
    //
    // Die Anmeldedaten muessen dabei wieder weg: librespot legt sie beim
    // Verbinden ab, und Klango meldet sich beim Start still damit an — ein
    // Gratis-Konto im Zwischenspeicher hiesse also, bei jedem Start erneut
    // gegen dieselbe Wand zu laufen.
    if !ist_premium(&sess).await {
        forget_credentials();
        sess.shutdown();
        return Err(NO_PREMIUM.to_string());
    }
    remember_credentials(&sess);
    Ok(sess)
}

/// Den Player fuer diese Session bauen; der Sink schreibt in einen frischen
/// Slot (SINK_SLOT), den open_track bzw. resume_track fuellt.
fn install_player(conn: &mut Conn, shared: &Arc<Shared>, sess: Session) {
    let slot: Arc<Mutex<Option<Arc<PcmFeed>>>> = Arc::new(Mutex::new(None));
    *SINK_SLOT.lock().unwrap() = Some(slot.clone());

    let player_config = PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        gapless: true,
        // Lautstärke-Normalisierung (wie Spotifys „Lautstärke anpassen", dort
        // standardmäßig an): librespot bringt Titel per ReplayGain auf ein
        // einheitliches, moderates Niveau — sonst gibt es Spotifys sehr laute
        // Master mit vollem Pegel aus und übertönt Klangos Sprache/Sounds
        // (es wirkte, als ignoriere Spotify die Klango-Lautstärke). Klangos
        // Master-/Otoczenie-Regler (F5/F6) greift weiterhin obendrauf.
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

/// Eine Abfrage mit lebender Session ausfuehren; scheitert sie an einem
/// NETZfehler (s. NET_TROUBLE), einmal neu verbinden und wiederholen.
/// Schlimmster Fall: REQ_TIMEOUT + CONNECT_TIMEOUT + REQ_TIMEOUT — deutlich
/// unter QUERY_TIMEOUT, so dass die Antwort Lua noch erreicht.
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
        crate::klog!("[spotify] {}: scheitert auch mit frischer Verbindung", what);
        return None;
    }
    crate::klog!("[spotify] {}: Netzproblem — verbinde neu und versuche es noch einmal", what);
    reset_trouble();
    if let Err(e) = reconnect(conn, shared, false, Resume::Keep).await {
        crate::klog!("[spotify] {}: Neuaufbau gescheitert: {}", what, e);
        return None;
    }
    op(conn.session.clone()?).await
}

/// Gemeinsamer Sink-Slot: der eine Ort, in den open_track den neuen Feed legt
/// und aus dem der Sink des AKTUELLEN Players liest. Getrennt von shared, weil
/// der Sink ihn schon zur Player-Bauzeit braucht. Jeder Player bekommt einen
/// eigenen Slot; retire leert den alten, damit ein abgeloester Player nichts
/// mehr in Klangos Feed schreibt.
static SINK_SLOT: Mutex<Option<Arc<Mutex<Option<Arc<PcmFeed>>>>>> = Mutex::new(None);

/// Page the browser shows after a successful login (Klangten sets a
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

/// OAuth-PKCE-Login im Browser (blockierend → spawn_blocking), mit
/// Zeitgrenze: bricht der Nutzer ab, soll der Engine-Thread nicht ewig warten.
async fn oauth_login() -> Result<Credentials, String> {
    OAUTH_WAITING.store(true, Ordering::SeqCst);
    let task = tokio::task::spawn_blocking(|| {
        use librespot_oauth::OAuthClientBuilder;
        let client = OAuthClientBuilder::new(SPOTIFY_CLIENT_ID, OAUTH_REDIRECT, OAUTH_SCOPES.to_vec())
            .open_in_browser()
            .with_custom_message(&login_page())
            .build()
            .map_err(|e| format!("OAuth-Client: {}", e))?;
        let token = client
            .get_access_token()
            .map_err(|e| format!("OAuth: {}", e))?;
        Ok(Credentials::with_access_token(&token.access_token))
    });
    let result = match tokio::time::timeout(OAUTH_TIMEOUT, task).await {
        Ok(r) => r.map_err(|e| format!("OAuth-Task: {}", e)).and_then(|x| x),
        Err(_) => {
            // Free the port: the listener thread is still waiting.
            cancel_login();
            Err("OAuth: keine Anmeldung im Browser".to_string())
        }
    };
    OAUTH_WAITING.store(false, Ordering::SeqCst);
    result
}

// ---- Metadaten / Suche / Bibliothek / Playlists ----

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
    // Hoerbuch-Kapitel und Podcast-Folgen sind EPISODEN, keine Titel — ohne
    // diesen Zweig blieben Name und Dauer leer (und damit das Spulen blind).
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
    let track = net("Titel", Track::get(session, &uri)).await?;
    Some(track_to_info(&track, uri_str))
}

/// Eine Zeile der typisierten Suche.
#[derive(Clone, Debug, Default)]
pub struct SearchRow {
    /// track | artist | album | playlist | audiobook | podcast
    pub kind: String,
    pub uri: String,
    pub name: String,
    /// Zweite Zeile: Interpret, Autor, Besitzer — je nach Art.
    pub sub: String,
    pub duration_ms: u32,
    /// Kennungen fuer das Alt-Menue eines Titels ("zum Kuenstler", "zum
    /// Album"). Bei einem Album ist nur `artist_uri` besetzt.
    pub artist_uri: String,
    pub album_uri: String,
}

/// Der Hash der gespeicherten Abfrage "searchDesktop" des Web-Players.
/// Spotify laesst ueber `pathfinder` NUR hinterlegte Abfragen zu; aendert der
/// Web-Player seine Version, antwortet der Dienst mit "PersistedQueryNotFound".
/// Dann faellt die Suche auf den Kontextweg zurueck (nur Titel) — sichtbar
/// bleibt sie also in jedem Fall.
const SEARCH_QUERY_HASH: &str =
    "d9f785900f0710b31c07818d617f4f7600c1e21217e80f5b043d1e78d74e6026";

/// Typisierte Suche ueber `pathfinder` — dieselbe Abfrage, die der Web-Player
/// benutzt. Sie ist der EINZIGE Weg zu Kuenstlern, Alben, Playlists,
/// Hoerbuechern und Podcasts: der spclient kennt nur die Titelsuche, und die
/// oeffentliche Web-API weist librespots Client-Kennung ab (429 auf jede
/// Anfrage, auch /v1/me — nachgemessen 28.08.2026). Angemeldet wird mit dem
/// login5-Token der laufenden Sitzung plus dem client-token des spclient.
async fn search_typed(
    session: &Session,
    query: &str,
    limit: usize,
) -> Option<Vec<SearchRow>> {
    let token = net("login5-Token", session.login5().auth_token()).await?;
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
        crate::klog!("[spotify] Suche ueber pathfinder: HTTP {}", resp.status());
        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            note_trouble("pathfinder: Token abgelaufen");
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

    // --- Titel (tracksV2 verpackt jede Zeile noch einmal in "item")
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

    // --- die uebrigen Sparten: alle nach demselben Muster items[].data
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
            // Name: Kuenstler tragen ihn unter profile.name, alle anderen direkt.
            let name = d
                .pointer("/profile/name")
                .or_else(|| d.get("name"))
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            // Zweite Zeile: Album -> Interpret, Hoerbuch -> Autor,
            // Playlist -> Besitzer, Podcast -> Verlag.
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
                // Ein Album fuehrt zu seinem Kuenstler; alles Uebrige hat
                // nichts, wohin es weiterfuehren koennte.
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

/// Ein Hoerbuch oder Podcast mit seinen Kapiteln/Folgen. Spotify fuehrt beide
/// als "Show": die Suche liefert `spotify:show:…`, die Kapitel sind Episoden —
/// und Episoden kann librespot abspielen.
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

/// Obergrenze fuer Titellisten (Mediathek, Playlist). Nicht als Sparmassnahme
/// gedacht, sondern als Notbremse gegen entartete Listen — der Normalfall soll
/// VOLLSTAENDIG geladen werden. Wird sie erreicht, steht es im Log.
pub const MAX_TRACKS: usize = 10_000;

/// Metadaten PARALLEL holen (max. 8 gleichzeitig): sequenziell dauerte die
/// Mediathek (100 × Track::get, je ein Roundtrip) selbst mit Rechenzentrums-
/// Anbindung ~3 s, auf einer Heim-Leitung 10-30 s — der blockierte Klango-
/// Hauptthread galt auf Windows dann als „Keine Rückmeldung". Reihenfolge
/// bleibt erhalten (Index-Join), Fehlschläge fallen einfach raus.
/// None = die Verbindung hat unterwegs versagt (NET_TROUBLE) — dann lieber
/// neu verbinden und wiederholen als eine löchrige Liste zeigen.
async fn tracks_from_uris(session: &Session, uris: &[String], limit: usize) -> Option<Vec<TrackInfo>> {
    if uris.len() > limit {
        crate::klog!(
            "[spotify] Liste gekuerzt: {} Titel vorhanden, {} geladen (Limit)",
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

/// Freitext-Suche über den internen spclient-Kontext (kein Web-API-Token).
async fn search_tracks(session: &Session, query: &str, limit: usize) -> Option<Vec<TrackInfo>> {
    let ctx_uri = search_context_uri(query);
    let ctx = net("Suchkontext", session.spclient().get_context(&ctx_uri)).await?;
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

/// Empfehlungen zu EINEM Titel — das "Song-Radio" des Spotify-Clients.
/// spclient antwortet auf `get_radio_for_track` mit der URI einer eigens
/// erzeugten Playlist ("inspired by"); deren Titel SIND die Empfehlungen.
/// (Die oeffentliche Web-API /v1/recommendations ist fuer librespots Client-ID
/// gesperrt — nachgeprueft am 28.08.2026: 429 auf jede Anfrage.)
async fn track_radio(session: &Session, track_uri: &str, limit: usize) -> Option<Vec<TrackInfo>> {
    let uri = SpotifyUri::from_uri(track_uri).ok()?;
    let bytes = net("Song-Radio", session.spclient().get_radio_for_track(&uri)).await?;
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

/// Namen zu Album-URIs holen (parallel, wie tracks_from_uris).
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

/// Kuenstlerseite: Name, Biografie, beliebteste Titel, Alben, aehnliche
/// Kuenstler — alles aus den Metadaten, die librespot ohnehin liefert.
async fn artist_details(
    session: &Session,
    artist_uri: &str,
    limit: usize,
) -> Option<ArtistDetails> {
    let uri = SpotifyUri::from_uri(artist_uri).ok()?;
    let a = net("Kuenstler", librespot_metadata::Artist::get(session, &uri)).await?;

    // Beliebteste Titel: die Liste des EIGENEN Landes; sonst die erste, die da
    // ist (Spotify fuehrt sie je Markt).
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

    // Alben: je Gruppe nur die aktuelle Veroeffentlichung.
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

/// Ein Album mit seinen Titeln (in Reihenfolge der CDs/Seiten).
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
    let ctx = net("Mediathek", session.spclient().get_context(&ctx_uri)).await?;
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

/// Eigene Playlists: rootlist (Protobuf) → Playlist-URIs → Namen nachladen.
async fn user_playlists(session: &Session, limit: usize) -> Option<Vec<PlaylistInfo>> {
    use librespot_protocol::playlist4_external::SelectedListContent;
    use protobuf::Message;

    let bytes = net("Playlist-Liste", session.spclient().get_rootlist(0, Some(limit))).await?;
    let slc = SelectedListContent::parse_from_bytes(&bytes).ok()?;
    let mut uris = Vec::new();
    if let Some(contents) = slc.contents.as_ref() {
        for item in contents.items.iter() {
            let uri_str = item.uri();
            if !uri_str.starts_with("spotify:playlist:") {
                continue; // start-group/end-group (Ordnermarken) überspringen
            }
            if uris.len() >= limit {
                break;
            }
            uris.push(uri_str.to_string());
        }
    }
    // Namen parallel nachladen (wie tracks_from_uris) — sequenziell blockte
    // das den Klango-Hauptthread pro Playlist einen Roundtrip lang.
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
        return None; // Namen fehlen wegen der Verbindung: neu verbinden, wiederholen
    }
    Some(out)
}

/// Titel öffnen: neuen Feed erzeugen (Format sofort gesetzt, damit _Snd_Load
/// nicht wartet), alten abbrechen, in den Sink-Slot + shared legen, laden.
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

    // Alten Feed stilllegen.
    if let Some(old) = shared.current_feed.lock().unwrap().as_ref() {
        old.cancel();
        old.mark_done();
    }

    let feed = PcmFeed::new_arc();
    feed.set_format(CH, SR);
    // Kleiner Ring (~2 s statt 10 s Radio-Standard): hält librespots Dekodier-
    // Vorlauf klein (Backpressure), damit EndOfTrack erst kurz vor dem hörbaren
    // Ende feuert und die hörbare Position dicht an der echten bleibt.
    feed.set_ring_max((SR * CH * 2) as usize);
    feed.set_state_ext("ok");

    // In BEIDE Buchführungen: Sink-Slot (woraus der Sink liest) + shared.
    if let Some(slot) = SINK_SLOT.lock().unwrap().as_ref() {
        *slot.lock().unwrap() = Some(feed.clone());
    }
    *shared.current_feed.lock().unwrap() = Some(feed.clone());

    // KANONISCHE URI merken: die Player-Events liefern die Track-URI über
    // SpotifyUri::to_uri() — genau diese Form muss in now.uri stehen, sonst
    // matcht is_current() nie (Positionsverfolgung + Ende-Erkennung tot, und
    // das Spulen spränge immer von Position 0).
    let canonical = uri.to_uri().unwrap_or_else(|_| uri_str.to_string());
    // Now-Playing minimal setzen (Titel/Interpret/Dauer holt ein
    // Hintergrund-Task nach) — so blockiert k_SpotifyOpen NICHT auf einem
    // Metadaten-Abruf. Das ist wichtig, weil der Kanal-Player playaudio()
    // (und damit open) bei JEDEM Titelwechsel im Frame-Takt aufruft.
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
    // Neuer Titel: kein laufendes Spulen mehr. Die Hoerbar-Basis ist die
    // Startstelle — bei einem fortgesetzten Hoerbuch also nicht 0.
    *shared.seek_target.lock().unwrap() = None;
    *shared.audible_base_ms.lock().unwrap() = start_ms;
    player.load(uri, true, start_ms);

    // Metadaten (v.a. Dauer fürs Spulen) asynchron nachtragen.
    {
        let sess2 = sess.clone();
        let shared2 = shared.clone();
        let want = canonical.clone();
        tokio::spawn(async move {
            if let Some(info) = fetch_track(&sess2, &want).await {
                let mut n = shared2.now.lock().unwrap();
                if n.uri == want {
                    // nur, wenn noch derselbe Titel läuft
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

/// `spotify:search:`-Kontext-URI bauen (Wörter mit `+`, Rest prozentkodiert).
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
// Öffentliche API für die Host-Globals (blockierend, mit Timeout)
// ---------------------------------------------------------------------------

/// Wie lange Lua auf eine Antwort wartet. Muss den schlimmsten Fall von
/// run_query abdecken (REQ_TIMEOUT + CONNECT_TIMEOUT + REQ_TIMEOUT = 26 s plus
/// die Zeit der eigentlichen Abfrage), sonst kaeme die Antwort eines
/// gelungenen zweiten Versuchs nie an.
const QUERY_TIMEOUT: Duration = Duration::from_secs(40);

/// Auf eine Engine-Antwort warten und dabei die Fenster-Event-Loop bedienen
/// (`pump`, wie speech.rs beim TTS-Rendern). OHNE das gilt das Fenster auf
/// Windows nach ~5 s ohne Message-Pumping als „Keine Rückmeldung" — es wird
/// geghostet und dem Nutzer wird „Programm beenden" angeboten. Genau das war
/// „Klango schließt sich bei Spotify": Mediathek/Playlists blocken sequenziell
/// metadatenholend viele Sekunden.
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

/// Login anstoßen (fire-and-forget) und aktuellen Status zurückgeben.
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

/// Empfehlungen zu einem Titel ("Song-Radio") — die Liste, mit der Klango
/// weiterspielt, wenn man einen EINZELNEN Suchtreffer startet.
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

/// Titel öffnen; gibt den PCM-Feed zurück (für _Snd_Load über SpotifyStream).
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
    // Nach außen zählt die HÖRBARE Position, nicht librespots Dekodier-
    // Position. Während eines laufenden Seeks steht in now.position_ms schon
    // das (optimistische) Ziel — das ist dann die bessere Auskunft.
    if !seeking(shared) {
        n.position_ms = audible_position_ms(shared);
    }
    n
}


#[cfg(test)]
mod tests {
    use super::search_context_uri;

    /// Engine-Erstkontakt ohne Anmeldung (wie Klango 3): Status lesen baut das
    /// Singleton samt tokio-Runtime; Abfragen ohne Session kommen leer zurück
    /// statt abzustürzen.
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

    /// ECHTER Ende-zu-Ende-Test (Netz + gespeicherte Anmeldung, darum
    /// #[ignore]): KLANGO_SPOTIFY_TEST_CACHE = Verzeichnis mit credentials.json.
    #[test]
    #[ignore]
    fn e2e_login_suche_wiedergabe() {
        let dir = std::env::var("KLANGO_SPOTIFY_TEST_CACHE")
            .expect("KLANGO_SPOTIFY_TEST_CACHE auf Cache-Dir mit credentials.json setzen");
        let _ = super::CACHE_DIR.set(std::path::PathBuf::from(dir));
        super::login();
        let mut s = String::new();
        for _ in 0..600 {
            s = super::status();
            if s == "ok" || s == "failed" || s == "nopremium" {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert_eq!(s, "ok", "Login-Status: {}", s);
        let tracks = super::search("kraftwerk", 5, &mut || {});
        assert!(!tracks.is_empty(), "Suche lieferte nichts");
        let feed = super::open(&tracks[0].uri, 0, &mut || {}).expect("open gab nichts");
        // Wie der Mischer: regelmäßig lesen und Frames zählen.
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
        assert!(total >= 44100, "kein PCM angekommen (state={})", feed.state());
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
        assert!(after >= 44100, "nach dem Spulen kam kein PCM mehr (gate={})", feed.is_gated());
        super::control("stop", 0);
    }

    #[test]
    fn suchkontext_uri() {
        assert_eq!(search_context_uri("hello world"), "spotify:search:hello+world");
        assert_eq!(search_context_uri("kraftwerk"), "spotify:search:kraftwerk");
        assert_eq!(search_context_uri("björk"), "spotify:search:bj%C3%B6rk");
    }
}
