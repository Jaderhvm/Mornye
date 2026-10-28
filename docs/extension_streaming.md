# Extension streaming fork

This fork keeps Mornye's existing UI. Catalog tracks from enabled extensions
declaring `capabilities.streaming = {version: 1, resolveAction: "resolvePlayback"}`
can be played without downloading a complete file. Local files remain preferred
in collection rows; explicit download actions remain available. Search-result
rows without a known local copy play supported extensions on tap. Other extensions
keep their existing behavior. This first integration starts one song per tap;
batch streaming queues and album Play All are not implemented yet.

The application ID is `com.jader.mornye.stream` and launcher label is Mornye Stream,
so the Android build coexists with the original. Debug appends `.debug` as upstream
does. Source namespace stays unchanged. This is a local fork branch, not an
already-published GitHub fork.

## Companion Deezer extension

Install `fork_extensions/deezer.sflx` (1.3.8) into this fork through the extension
import flow. The package includes its reviewable JavaScript source, manifest,
LICENSE, COPYING and NOTICE. Modified upstream source also remains in the sibling
`mornye-extension/sources/deezer/` checkout. Keep the app and extension together:
the official 1.3.7 extension does not declare streaming support. Complete its
normal session verification in extension settings before playback. No credentials
or service calls are included in the offline tests.

`resolvePlayback({track_id})` uses the plugin's existing signed ticket and resolver
flow. It returns `{success, url, headers, mime_type, transform?}` and never calls
file download APIs. `transform`, when present, declares independent Blowfish-CBC
segments with a hex key and IV, segment size, repetition interval and offset. It
matches the extension's existing file-transform algorithm and resets CBC for each
selected full segment. Partial trailing segments are not transformed.

The app uses the existing generic extension action bridge. No provider-specific
branches or Rust ABI changes are needed. Queue persistence stores only
`extension-audio:///extension-id/track-id`, not expiring URLs or transform keys.
Each load resolves a fresh source. A loopback HTTP proxy streams and transforms
bounded segments in memory, aligns seeks to segment boundaries and trims the
response to the requested byte range. A 401/403 refreshes the descriptor once.
The proxy does not create music files. It validates the extension's declared host
permissions for every redirect and socket; pins sockets to public DNS results;
uses an unpredictable local token; and does not log URLs, headers or keys.

## Limitations and validation

Only complete HTTP audio with a known byte length is supported. Single byte ranges
are supported; suffix/multipart ranges and HLS/DASH are not. A remote server that
ignores a nonzero range cannot seek. Direct USB/bit-perfect playback and AutoMix
analysis of entire local files are not available for these streams. A disabled
extension is rechecked at each load or expired-link refresh; an already-open HTTP
response is allowed to finish. Inactive proxy handles are bounded and expire on
the next load. They and their keys are process-memory only.

Tests cover a published cipher vector, arbitrary network chunk boundaries,
partial final segments, range alignment, permission checks, stable identities,
the generic action bridge, incremental playback before EOF, HEAD requests,
nonzero ranges and expired-link renewal. Existing playback-failure tests pass on
Windows. Four upstream restore tests assume POSIX paths and fail on Windows;
they are unchanged and should also run on Linux before shipping.

Flutter 3.47.7 (pinned by upstream) and its required framework patch have been
prepared locally. The upstream Android native build script explicitly supports
Linux/macOS, not Windows. A manual `Build Mornye Stream preview` Actions workflow
is prepared for a connected GitHub fork. It uses Linux, the pinned SDK/NDK/Rust
toolchain and Lite mode (no optional proprietary Discord SDK). Its APK is signed
with a test key and is a preview, not a production release. The workflow has not
been run, no APK has been generated, and playback against Deezer has not been
verified on the S24 Ultra yet.

Retain upstream LGPL-3.0 notices and corresponding source when distributing a
modified build. Neither the official Mornye project nor the plugin authors have
reviewed or endorsed these changes.
