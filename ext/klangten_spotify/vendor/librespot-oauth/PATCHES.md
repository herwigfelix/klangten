# Patches to librespot-oauth

This directory is librespot-oauth 0.8.0 as published on crates.io (MIT
licence, see `LICENSE`, copied from the upstream repository
https://github.com/librespot-org/librespot because the package does not
contain it). Klangten's `Cargo.toml` uses it through `[patch.crates-io]`.

Three changes in `src/lib.rs`, marked `KLANGTEN PATCH`:

1. Failed token exchanges report the whole chain of causes (`error_chain`);
   oauth2 alone says only "Request failed".
2. `get_access_token` retries the code exchange for up to three minutes
   while the request cannot leave the device (`not_sent`: connect/DNS
   errors). Android blocks the network of an app in the background, and
   during the sign-in the browser is in front: the exchange failed with "dns
   error" before Spotify ever saw the code. The code is still unused then,
   so the retry succeeds as soon as the user is back in Klangten.
3. `set_url_opener(fn(&str))`
registers a function that opens the authorization page instead of the `open`
crate. On Android `open` tries `xdg-open`, `gio` and friends, none of which
exist, and fails silently - the login then waited for a page nobody saw.
klangten_spotify registers an opener on Android that hands the address to
Klangten (`ks_take_login_url`), which opens it through the system.

Every other file is unchanged; compare with

    curl -L https://crates.io/api/v1/crates/librespot-oauth/0.8.0/download | tar xz
    diff -u librespot-oauth-0.8.0/src/lib.rs vendor/librespot-oauth/src/lib.rs
