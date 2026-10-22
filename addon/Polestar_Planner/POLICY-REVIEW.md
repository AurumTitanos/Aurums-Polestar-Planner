# Publication and addon-policy review

Policy and licensing notes for **0.1.11**, reviewed **2026-10-22**.
This is an unofficial addon; Blizzard has not certified this release.

## Blizzard addon rules

Primary policy:
https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534

This release is free, contains readable Lua/XML, has no paywall, advertisement
or in-game donation request, and ships no external gameplay process. The
reviewed companion presents guide/map data through WoW APIs. Its NPC-target
button requires a user click and uses a secure action template; it does not
perform unattended movement, combat or quest acceptance. Quest-dialog hooks
observe events for local diagnostics rather than selecting or accepting quests.
The companion has no network telemetry or automatic chat/addon-message sending.
No extracted Blizzard texture assets are bundled. The screenshots show gameplay;
all third-party artwork retains its original rights.

These characteristics are consistent with the published addon guidelines.
Blizzard can still restrict APIs or disable addon behavior, and performance
cannot be guaranteed for every installation. This review does not establish
that a particular third-party/private server is authorized by Blizzard, or
claim compatibility with every official WoW client. The server's own rules
and applicable Blizzard terms remain separate from publishing addon source.

## GPL and other licenses

Polestar's LICENSE grants GPL version 3 redistribution/modification rights.
Its LICENSE-EXCEPTION.md explicitly excludes Polestar code from the guide-pack
exception, so that exception is not used for this companion. Original notices,
the full GPL and modification credits are retained, with readable corresponding
source and the release packaging/local-mask tools supplied in the repository.
MIT OpenMap notices and the Shortest Path Forever attribution remain intact.
The optional separately installed addons are not relicensed or bundled here.

Primary GPL texts and guidance:
https://www.gnu.org/licenses/gpl-3.0.html
https://www.gnu.org/licenses/gpl-faq.html#TranslateCode

The release contains addon code and documentation, without account saves or
personal macro imports.
