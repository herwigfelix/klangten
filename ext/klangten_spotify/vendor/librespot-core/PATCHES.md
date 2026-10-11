# Patches to librespot-core

This directory is librespot-core 0.8.0 as published on crates.io
(MIT licence, see `LICENSE` in this directory; upstream:
https://github.com/librespot-org/librespot). Klangten's `Cargo.toml` uses it
through `[patch.crates-io]`, so every librespot crate picks up this copy.

There are two changes, both in `src/session.rs` and marked `KLANGTEN PATCH`:

1. `Session::check_catalogue` no longer calls `process::exit(1)` for an
   account without Premium. Upstream this terminates the whole host process
   (the product information arrives asynchronously after login, so the host
   disappeared without a message, and again on every start after a silent
   re-login). Instead the fact is recorded in a global flag, read with
   `non_premium_seen()` and cleared with `reset_non_premium()`;
   klangten_spotify then aborts the login in an orderly way.
2. The wall-clock time of the last packet from the access point is recorded,
   and `Session::millis_since_last_packet()` reports how long ago that was.
   librespot's keep-alive timers run on the monotonic clock, which stands
   still while a Mac sleeps, so a dead session could still count as healthy
   for minutes after waking up; klangten_spotify reconnects when no packet
   has arrived for too long.

Every other file is unchanged from the crates.io package (`LICENSE` was added
from the upstream repository because the package does not contain it, and
`.cargo_vcs_info.json` was left out). A unified diff can be produced against
the crates.io package at any time, for example:

    curl -L https://crates.io/api/v1/crates/librespot-core/0.8.0/download | tar xz
    diff -u librespot-core-0.8.0/src/session.rs vendor/librespot-core/src/session.rs

The current diff:

```diff
--- a/src/session.rs
+++ b/src/session.rs
@@ -3,7 +3,6 @@
     future::Future,
     io,
     pin::Pin,
-    process::exit,
     sync::{Arc, OnceLock, RwLock, Weak},
     task::{Context, Poll},
     time::{Duration, SystemTime, UNIX_EPOCH},
@@ -115,8 +114,22 @@
     cache: Option<Arc<Cache>>,
 
     handle: tokio::runtime::Handle,
+
+    /// KLANGTEN PATCH: wall-clock time (ms since 1970) of the last packet
+    /// received from the access point. See `Session::millis_since_last_packet`.
+    last_rx_ms: std::sync::atomic::AtomicU64,
 }
 
+/// KLANGTEN PATCH: wall clock in ms. DELIBERATELY not `Instant`: the monotonic
+/// clock stands still on macOS while the computer sleeps — exactly when the
+/// connection dies, the keep-alive timers (tokio, monotonic) noticed nothing.
+fn patch_now_ms() -> u64 {
+    SystemTime::now()
+        .duration_since(UNIX_EPOCH)
+        .map(|d| d.as_millis() as u64)
+        .unwrap_or(0)
+}
+
 /// A shared reference to a Spotify session.
 ///
 /// After instantiating, you need to login via [Session::connect].
@@ -128,7 +141,25 @@
 /// an unexpectedly closed connection, you'll need to create a new [Session].
 #[derive(Clone)]
 pub struct Session(Arc<SessionInternal>);
+
+/// KLANGTEN PATCH: set as soon as Spotify reports an account WITHOUT Premium.
+/// Global, because `check_catalogue` is an associated function without
+/// `self` — and because only one login runs at a time in a process anyway.
+pub static NON_PREMIUM: std::sync::atomic::AtomicBool =
+    std::sync::atomic::AtomicBool::new(false);
 
+/// KLANGTEN PATCH: has Spotify reported an account without Premium for the
+/// current login? Reset with `reset_non_premium()` before a new login
+/// attempt.
+pub fn non_premium_seen() -> bool {
+    NON_PREMIUM.load(std::sync::atomic::Ordering::SeqCst)
+}
+
+/// KLANGTEN PATCH: resets the flag before a new login attempt.
+pub fn reset_non_premium() {
+    NON_PREMIUM.store(false, std::sync::atomic::Ordering::SeqCst);
+}
+
 impl Session {
     pub fn new(config: SessionConfig, cache: Option<Cache>) -> Self {
         let http_client = HttpClient::new(config.proxy.as_ref());
@@ -157,6 +188,7 @@
             token_provider: OnceLock::new(),
             login5: OnceLock::new(),
             handle: tokio::runtime::Handle::current(),
+            last_rx_ms: std::sync::atomic::AtomicU64::new(patch_now_ms()),
         }))
     }
 
@@ -361,14 +393,28 @@
         );
     }
 
+    /// KLANGTEN PATCH (the first of two; the second is the timestamp
+    /// `last_rx_ms` / `millis_since_last_packet`).
+    ///
+    /// Upstream, this function ends with `exit(1)` for an account without
+    /// Premium — it terminates the PROCESS that embeds librespot. For an
+    /// embedding host that is fatal: the product information arrives
+    /// asynchronously after login, so the host vanished in the middle of
+    /// operation without any message. And because the credentials had
+    /// already been stored at login and the host logs in again silently on
+    /// startup, it then died again on EVERY start — it could no longer be
+    /// used.
+    ///
+    /// An embedded library must not terminate its host's process. We only
+    /// record the fact; `non_premium_seen()` exposes it, and the caller
+    /// (klangten_spotify, src/engine.rs) then aborts the login in an orderly
+    /// way (message to the user, credentials NOT stored).
     fn check_catalogue(attributes: &UserAttributes) {
         if let Some(account_type) = attributes.get("type") {
             if account_type != "premium" {
                 error!("librespot does not support {account_type:?} accounts.");
                 info!("Please support Spotify and your artists and sign up for a premium account.");
-
-                // TODO: logout instead of exiting
-                exit(1);
+                NON_PREMIUM.store(true, std::sync::atomic::Ordering::SeqCst);
             }
         }
     }
@@ -644,6 +690,28 @@
 
     pub fn is_invalid(&self) -> bool {
         self.0.data.read().expect(SESSION_DATA_POISON_MSG).invalid
+    }
+
+    /// KLANGTEN PATCH: for how long (wall clock, ms) has nothing arrived from
+    /// the access point?
+    ///
+    /// The server sends a ping or PongAck at least every 60 s. If the value
+    /// is well above that, the connection is dead, even if `is_invalid()`
+    /// does not know it yet: librespot's keep-alive timers run on the
+    /// monotonic clock, which stands still during sleep — after waking up, a
+    /// long-dead session thus still counted as healthy for minutes.
+    pub fn millis_since_last_packet(&self) -> u64 {
+        patch_now_ms().saturating_sub(
+            self.0
+                .last_rx_ms
+                .load(std::sync::atomic::Ordering::Relaxed),
+        )
+    }
+
+    fn patch_mark_rx(&self) {
+        self.0
+            .last_rx_ms
+            .store(patch_now_ms(), std::sync::atomic::Ordering::Relaxed);
     }
 }
 
@@ -886,6 +954,7 @@
         loop {
             match self.as_mut().project().stream.try_poll_next(cx) {
                 Poll::Ready(Some(Ok((cmd, data)))) => {
+                    session.patch_mark_rx(); // KLANGTEN PATCH: record a sign of life
                     let result = self.as_mut().dispatch(&session, cmd, data);
                     if let Err(e) = result {
                         debug!("could not dispatch command: {e}");
```
