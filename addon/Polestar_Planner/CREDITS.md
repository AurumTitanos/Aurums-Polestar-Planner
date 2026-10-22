# Attribution and adaptation history

## Polestar — the original Planner

Original work: **Fitz and The Polestar authors**, Copyright (c) 2026.
Source: https://github.com/fitzforge/polestar

Polestar created the original browser-based Planner. This project adapts that
Planner into an in-game Lua companion with a full dashboard, movable compact
map and optional Questie overlays. It must not be presented as an original
Planner invented by this project's maintainer or as an official Polestar release.

The initial UI/map/widget extraction came through the local viewer adaptation
at commit `8294ca91bc89f310bffaaf3cfb392c85f441598d`. This is a provenance
identifier for a historical local adaptation, not a required public checkout.
The dependency adapter was updated for stock Polestar 0.2.6. The public release
is a fresh source export, not a publication of the private project's Git history.

**Modifications by AurumTitanos, 2026:** in-game Lua dashboard and compact map,
independent namespace/preferences/lifecycle, Polestar read adapter, optional
Questie map presentation and performance work, party/instance/travel displays,
0.2.6 compatibility and public packaging. The original namespaces in copied
comments identify upstream provenance. Public packaging dated **2026-10-22**
removes personal macro tools and redistributable-media assumptions, and uses
installed dependencies' media instead. Copyright notices in LICENSE remain.

Polestar's guide-pack exception does **not** cover Polestar code. This derivative
companion is therefore published under GPL version 3, not under that exception.
The entire corresponding source for the shipped Lua is in `addon/Polestar_Planner`.
No separate binary-only engine or mandatory private service is used.

## OpenMap

**jiforever and the OpenMap contributors**, Copyright (c) 2026, MIT.
Embedded renderer/data adapted from the unofficial mirror:
https://github.com/fitzforge/wowforever-openmap/tree/849bac460b6ebcb110ef80fc27a6b08565069c74

The mechanical embedding gives each Planner view independent renderer closures
and pauses background renderer jobs while hidden. It does not replace OpenMap's
ordinary world map. `addon/Polestar_Planner/OpenMap/LICENSE.txt` retains the
full MIT notice. Its texture notice remains for provenance only: **the textures
are not distributed here**. The optional native mask tool transforms locally
installed artwork; its output remains Blizzard's artwork, not GPL or MIT art.

## Shortest Path Forever

Portions Copyright (C) 2026 **Cillian Berragan**:
https://github.com/cjber/shortest-path-forever
GPL-3.0-or-later, incorporated under GPL version 3. See the original
attribution header in `Maps/RouteStrokes.lua` and the retained LICENSE.

## Runtime dependencies and other rights

Polestar supplies UI icons and Inter fonts at runtime. Font author: **Rasmus
Andersson**, SIL Open Font License 1.1; the font binaries are not bundled here.
Questie and optional ForeverDungeonScout remain separately installed addons;
no database or artwork from them is redistributed. Blizzard Entertainment owns
World of Warcraft and its artwork. Numeric texture IDs, coordinate metadata and
API names are used for interoperability; game assets remain in the client or
separate addons. The GPL does not grant rights to Blizzard's trademarks/artwork.

## Screenshots

The maintainer supplied the three gameplay screenshots for publication. They
show the original private setup with OpenMap artwork. World of Warcraft game
art remains copyright Blizzard Entertainment; no ownership of it is claimed
and it is not relicensed under GPL/MIT. Screenshots are documentation, not
reusable texture assets supplied to the addon.
