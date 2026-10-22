# Source and checks

The installed Lua/XML is the preferred editable source; no minifier or bytecode
step is used. With Python 3 installed, run `python3 tools/package.py` to create
the install ZIP and SHA256SUMS under `.dist`. The packager excludes all local
media, personal macro tools, logs, saves and unrelated directories.

Tests need Node.js and Lua 5.1. Supply an unmodified stock Polestar 0.2.6 source
checkout with its released addon under `addon/Polestar` and upstream test stubs:

```sh
POLESTAR_STOCK_DIR="/path/to/polestar-0.2.6" LUA=lua5.1 npm test
```

Polestar is separately licensed GPLv3 and must be obtained separately from
https://github.com/fitzforge/polestar/tree/v0.2.6 . No upstream source checkout
or game client is bundled in this repository. Tests stub the client; passing
checks are not a substitute for live-client validation.

`tools/native-mask.cjs` contains the deterministic alpha-union transformation
used for the optional island fix. `tools/prepare-map-mask.cjs` checks the two
input textures against their pinned OpenMap provenance before writing the local
output; mismatched inputs are rejected. The texture binaries are not committed
or packed. Existing native map metadata fixtures use client-table facts, not
account or character data.
