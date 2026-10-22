# Validation of public preview 0.1.11

Checked **2026-10-22** against stock **Polestar 0.2.6** and Lua 5.1.

- **195 tests passed; zero failures or skips.** The suite loads the actual
  companion Lua with stock Polestar and simulated client API fixtures.
- Coverage includes full/compact windows, separate preferences and core state,
  guide/map projection, optional Questie pins and hover details, bounded pin
  refresh work, travel/flight zoom, party/instance maps, secure click targeting,
  deferred combat writes, unsafe-name rejection and local quest diagnostics.
- The public-export test explicitly rejects OpenMap file textures and confirms
  that native terrain tiles, player marker and route overlays remain usable.
- The optional mask generator reproduced the working private build's island
  mask **byte for byte**, from the pinned locally available OpenMap inputs.
  Generated mask SHA-256:
  `d7eab1f49d5b0a13c022bafb7add9691d7bc7355d19abbc34dface91c5424380`.
- Source/export privacy checks and ZIP inventory checks found no credentials,
  personal filesystem paths, character saves, personal macro tools or texture
  binaries. The public repository starts with fresh Git history.

These are automated checks, not a new live-client visual/play test. The prior
private dashboard and compact map were used in game; the public package's
external-media paths and optional OpenMap installation still need live-user
validation. No claim of compatibility with later Polestar versions or other
WoW client variants is made.
