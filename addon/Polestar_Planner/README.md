# Aurums Polestar Planner

A **free companion addon for Polestar on WoW Forever**. I adapted Polestar's
browser Planner into an in-game Lua window, with a movable compact map,
live guide and character information, and optional Questie markers.

**Fitz and the Polestar authors created the original Planner.** This addon builds
on their work and is an independent community adaptation. Polestar still handles
the guide engine and progression.

## Screenshots

Main in-game Planner:

![Full Planner with guide steps, route map and live character panel](https://raw.githubusercontent.com/AurumTitanos/Aurums-Polestar-Planner/main/docs/images/main-planner.png)

Movable compact map:

![Compact map showing the current route and Questie markers](https://raw.githubusercontent.com/AurumTitanos/Aurums-Polestar-Planner/main/docs/images/compact-map.png)

Compact map zoomed out:

![Compact map showing a wider Eastern Kingdoms view](https://raw.githubusercontent.com/AurumTitanos/Aurums-Polestar-Planner/main/docs/images/compact-map-wide.png)

This is my setup with **OpenMap**. Install OpenMap separately for the map
appearance shown here; without it, the addon uses the client's terrain map.

## Download and install

1. Install [Polestar](https://github.com/fitzforge/polestar) **0.2.6** separately.
2. Download **Polestar_Planner-0.1.11.zip** from the
   [release page](https://github.com/AurumTitanos/Aurums-Polestar-Planner/releases/tag/v0.1.11).
3. Extract the **Polestar_Planner** folder into the same `Interface/AddOns`
   directory as Polestar. The `.toc` must be directly inside that folder.
4. Restart WoW, enable both addons, then use **`/psplanner`** or **`/psmap`**.

The addon works with whichever compatible guide pack you use. No guide pack is
bundled. [Aurums Night Elf Druid Guide](https://github.com/AurumTitanos/Aurums-Night-Elf-Druid-Guide)
is available separately.

## What it adds

- A full live Planner window and a separate draggable, resizable compact map.
- Guide objectives, route lines, spawn regions, service markers and character details.
- Optional **Questie** pins and expanded hover details, read from your installed
  Questie without moving its frames or replacing its tracker integration.
- Party/raid markers and instance terrain where the client exposes usable maps
  and coordinates; optional interior references use an installed ForeverDungeonScout.
- Travel status and follow/automatic zoom. Unknown travel times stay unknown.
- Separate preferences in `PolestarPlannerDB`; Polestar retains guide progress.

Open the full view with `/psplanner`; toggle the small map with `/psmap` or
`/psplanner minimap`. Key bindings are under **AddOns > Polestar Planner**.
`/psplanner perf` displays Questie pin-worker timing. `/psplanner help` lists
entry points.

## Map artwork

The basic terrain map references textures already in the WoW client. **No
extracted Blizzard map artwork or reusable texture files are bundled.**
UI icons and fonts come from the required Polestar installation.

For the stitched, named OpenMap appearance, install **OpenMap** separately. The
embedded MIT renderer was adapted from
[fitzforge/wowforever-openmap](https://github.com/fitzforge/wowforever-openmap)
commit `849bac460b6ebcb110ef80fc27a6b08565069c74`, an unofficial mirror of
**jiforever and the OpenMap contributors'** work. Other OpenMap versions have not
been verified. Missing artwork leaves the native terrain fallback available.

For the detailed Kalimdor/Teldrassil stitched view, the optional island-mask
repair must be generated **locally from your own installed OpenMap textures**.
With Node.js installed, run from a source checkout:

```sh
node tools/prepare-map-mask.cjs "/path/to/Interface/AddOns/OpenMap" "/path/to/Interface/AddOns/Polestar_Planner"
```

Restart WoW afterwards. This reads two OpenMap masks and generates the repaired
mask inside the Planner folder. Without it, Kalimdor uses the native terrain
fallback. The external-media setup has automated coverage but still needs
in-game visual testing.

## Compatibility and status

**Community preview 0.1.11**, targeting **Polestar 0.2.6** and the Forever client
(`Interface: 16001`). Later Polestar versions may need an adapter update.
Retail and Midnight compatibility is not supported.

I've used the full Planner and compact map in game. The release also passes
**195 automated tests**. The separate OpenMap asset setup still needs in-game
visual testing; see [VALIDATION.md](VALIDATION.md) for coverage and limitations.

## Credits and license

- **Fitz and The Polestar authors** — original Polestar and browser Planner;
  GPL-3.0-only. Original copyright/license notices are preserved.
- **AurumTitanos** — the independent in-game Lua adaptation, compact-map and
  Questie presentation work, companion extraction and public packaging.
- **jiforever and OpenMap contributors** — embedded isolated renderer/data;
  MIT. The original license is included.
- **Cillian Berragan / Shortest Path Forever** — route-stroke code adapted
  through Polestar; original GPL-3.0-or-later notice retained.
- **Questie contributors** — optional runtime data integration; no Questie code
  or database is bundled. **Blizzard Entertainment** owns the game and game art.

The combined companion code is **GPL-3.0-only**, with third-party notices
preserved. Readable Lua is both the installed program and its source. The
repository also contains tests and the optional local mask generator.
See [LICENSE](LICENSE), [CREDITS.md](CREDITS.md) and
[POLICY-REVIEW.md](POLICY-REVIEW.md). No affiliation or endorsement by Blizzard,
Polestar, Questie or OpenMap is claimed.
