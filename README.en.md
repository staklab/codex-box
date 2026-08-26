# codex-box

`codex-box` is a macOS menu bar companion designed to coexist with the official
Codex Desktop app without rewriting its shared OAuth credentials.

[简体中文](README.md)

## Highlights

- Treats `~/.codex/auth.json` as read-only for account-management workflows
- Keeps read-only usage polling without token-refresh fallback
- Scans local Codex sessions for token and cost estimates
- Launches isolated Codex CLI profiles with a separate `CODEX_HOME`
- Provides an optional local account gateway with automatic config restoration
- Supports multiple public theme catalogs and local themes
- Injects wallpaper and glass styling through a loopback CDP connection
- Performs surgical `config.toml` updates that preserve unrelated user keys

## Security boundaries

- OAuth rotation and Codex Home credential writes inherited from the upstream
  account-switching workflow are disabled.
- Skin injection requires a randomized loopback CDP port. Other local processes
  may control the renderer while that port is open. The feature is opt-in and
  injects styles only.
- The optional account gateway is disabled by default and restores the official
  direct configuration when codex-box exits.
- Theme assets may have per-theme licenses. Runtime catalog access does not
  grant redistribution rights.

## Platform support

The current release is **macOS-only** and requires macOS 13 or later. GitHub
Releases provide a macOS DMG. Windows and Linux builds are not currently
available.

Download: [v1.2.8 macOS Release](https://github.com/staklab/codex-box/releases/tag/v1.2.8)

## Build

The current Swift 6.3.3 optimizer crashes on a project `deinit` path, so Release
builds must explicitly use `SWIFT_OPTIMIZATION_LEVEL=-Onone`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project codex-box.xcodeproj \
  -scheme codex-box \
  -configuration Release \
  -derivedDataPath /tmp/ddbox \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  build
```

## Upstream and licenses

This project is an MIT-licensed derivative of
[lizhelang/codexbar](https://github.com/lizhelang/codexbar). Its skin direction
was informed by [CodexPlusPlus](https://github.com/BigPizzaV3/CodexPlusPlus)
and interoperates with the MIT-licensed
[CodexPlusPlus-Themes](https://github.com/BigPizzaV3/CodexPlusPlus-Themes) and
[Codex-Dream-Skin](https://github.com/Fei-Away/Codex-Dream-Skin) ecosystems.

CodexPlusPlus itself is AGPL-3.0. No CodexPlusPlus source code or assets are
included or adapted here; the macOS implementation is independently written
in Swift.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
[FORK_RATIONALE.md](FORK_RATIONALE.md), and
[docs/UPSTREAM_ATTRIBUTION.md](docs/UPSTREAM_ATTRIBUTION.md).

## License

[MIT](LICENSE). This is not an official OpenAI product.
