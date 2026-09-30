# Standard Infernus collision

`infernus_standard.col` is the 4,528-byte COL3 collision payload extracted from
the original `infernus.dff` in GTA San Andreas `models/gta3.img`.
Its internal name is `infernus_col`.

SHA-256: `3c194a973103b383f2634bc23f98b6cebd906f731a131cf43bd4328b8fe395d3`

Every bundled Infernus DFF contains this exact payload in its collision plugin
(`0x253F2FA`). The separate COL files in that category also match this reference.
The Python import tool applies the same normalization to new Infernus imports.

MTA loads vehicle collision from the DFF. This reference is used by development
tools; it is not loaded with `engineReplaceCOL` or downloaded separately.

Audit: `python tools/normalize_infernus_collision.py`

Normalize manually added Infernus mods (creates a backup first):
`python tools/normalize_infernus_collision.py --apply`

The tool preserves non-collision chunks and file padding, adjusting parent
chunk lengths if a mod previously contained a differently sized collision.
