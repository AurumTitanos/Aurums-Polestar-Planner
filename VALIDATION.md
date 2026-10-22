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
- The optional mask generator reproduced the original island repair
  **byte for byte**, using the supported OpenMap inputs.
  Generated mask SHA-256:
  `d7eab1f49d5b0a13c022bafb7add9691d7bc7355d19abbc34dface91c5424380`.

I've used the dashboard and compact map in game. These automated checks cover
the release's code, but the separate OpenMap asset setup still needs in-game
visual testing. Later Polestar versions and other WoW clients are not covered.
