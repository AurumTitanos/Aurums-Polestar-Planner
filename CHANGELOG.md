# Changelog

## 0.1.11 — 2026-10-22 — first public community preview

Based on the private 0.1.10 companion tested with Polestar 0.2.6. Publishes the
in-game Lua Planner and movable compact map with optional Questie integration.
Credits Fitz and the Polestar authors for the original browser Planner.

The public export removes the one-off personal macro import, reads UI media
from the required Polestar installation, and reads optional stitched art from
an installed OpenMap copy. It ships no game-art binaries. An optional local
island-mask generator preserves the detailed Kalimdor/Teldrassil repair without
publishing the derived artwork. Native terrain remains the fallback.

This source export does not modify an existing user's installed addon or saves.
