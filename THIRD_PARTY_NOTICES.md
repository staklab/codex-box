# Third-Party Notices

`codex-box` is an independently published derivative of
[lizhelang/codexbar](https://github.com/lizhelang/codexbar). The direct
upstream is licensed under the MIT License and explicitly permits use,
modification, publication, distribution, sublicensing, and sale, provided its
copyright notice and license text are retained.

## Direct upstream: lizhelang/codexbar

- Repository: <https://github.com/lizhelang/codexbar>
- License: MIT
- Copyright: `Copyright (c) 2025 codexbar contributors`

The upstream MIT notice is preserved in this repository's [`LICENSE`](LICENSE).

The attribution chain documented by the direct upstream is:

- [xmasdong/codexbar](https://github.com/xmasdong/codexbar) — MIT
- [steipete/CodexBar](https://github.com/steipete/CodexBar) — MIT

## Theme ecosystem and implementation references

### CodexPlusPlus

- Repository: <https://github.com/BigPizzaV3/CodexPlusPlus>
- License: GNU Affero General Public License v3.0 (AGPL-3.0)

CodexPlusPlus informed the product direction for an external CDP-based skin
manager and theme market. `codex-box` does not include or adapt source code or
assets from the CodexPlusPlus AGPL repository; its macOS implementation is an
independent Swift implementation. This notice credits the design reference and
does not relicense CodexPlusPlus code.

### CodexPlusPlus-Themes

- Repository: <https://github.com/BigPizzaV3/CodexPlusPlus-Themes>
- Repository tooling and manifest structure: MIT
- Copyright: `Copyright (c) 2026 CodexPlusPlus Themes contributors`

`codex-box` can read this public theme catalog at runtime. Individual themes,
images, fonts, and other assets remain governed by the `LICENSE.md` in each
theme directory. Runtime catalog compatibility does not grant additional
rights to redistribute a theme's assets.

### Codex-Dream-Skin

- Repository: <https://github.com/Fei-Away/Codex-Dream-Skin>
- License: MIT
- Copyright: `Copyright (c) 2026 Codex Dream Skin Studio contributors`

The project is credited as an open reference for external CDP skin injection,
the Dream Skin theme schema, and the DreamSkin.cc ecosystem.

## Notes

- `codex-box` is not an official OpenAI product.
- OpenAI, Codex, ChatGPT, and third-party project names and marks belong to
  their respective owners.
- Downloaded themes are not bundled into this source repository. Users and
  distributors must review the license and asset rights of each theme.
- See [`FORK_RATIONALE.md`](FORK_RATIONALE.md) for the technical rationale and
  [`docs/UPSTREAM_ATTRIBUTION.md`](docs/UPSTREAM_ATTRIBUTION.md) for contributor
  and attribution workflow guidance.
