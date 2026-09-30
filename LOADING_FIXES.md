# Loading fixes — 2026-09-30

## Subsequent collision and access update

After the loading fixes, ingame switching was reported working. All 85 bundled
Infernus variants were then updated to the exact stock model-411 collision, as
were their 14 standalone COL files. Their non-collision data is preserved. See
`assets/README.md` for the source and reference hash. The importer normalizes new
Infernus imports automatically; manual additions need the normalization tool.

`Config.Permission.publicUse = true` now permits guests to use the local panel
without ACL membership. Global changes still require their separate permission.
The earlier optional Editor ACL entries can remain, but are no longer necessary
for opening VMM. Server resource-management commands retain their own permissions.

The new collision behavior needs ingame physics testing; the prior successful
switching test predates this update. Python tests verify collision equality,
preservation of other data, repeatability, and the importer. Lua permission tests
verify public guests, optional restricted mode and global permission separation.

The client log showed repeated model 411 replacement failures and a TXD load
failure for Infernus #024 gorex. These repairs address confirmed code and asset
defects; successful rendering of every car and the original crash still need
verification in MTA.

## Changes

- `client.lua`: import TXDs before loading DFFs; skip standalone COLs on vehicle
  and ped models; check load/import/replace results and log the mod, file, step
  and model ID on failure. Unwind partial loads, free DFFs/shaders before their
  textures, and restore the previously committed mod after failed activation.
- `gui.lua`: stop failed previews, clean up the preview vehicle and unfreeze the
  player after a texture-preview failure. Partial previews cannot count as a
  fully activated mixed model/texture mod.
- `server.lua`: reset the hash cache during rescans so same-size asset edits
  receive new content hashes and clients download the repaired versions.
- Corrected 25 Infernus DFF clump length fields that incorrectly included the
  12-byte chunk header. Nested chunks were complete and validated before repair;
  only bytes in the outer length field changed. Geometry is unchanged.
- Corrected the DXT1 texture `31312Outro` in Infernus #024 from 751×580 to
  752×580. Its existing 218,080-byte payload already contains all 188×145 DXT1
  blocks. This exposes the existing padded edge column rather than recompressing
  the pixels; the texture's horizontal mapping changes by less than 0.14%.

## Validation

- All five Lua files pass syntax checks using the installed MTA Lua 5.1 DLL.
- Offline Lua tests cover texture-before-DFF ordering, skipping vehicle COLs,
  failures at each model-loading step, failed texture previews, cleanup order,
  sharing one TXD across wheel entries, partial previews, and restoring the
  previous committed mod after failed activation. These use engine stubs, not
  the real GTA renderer.
- All 210 DFF/TXD assets pass the repair tool's chunk/mip checks; a second audit
  reports zero remaining instances of the supported header defects.
- Compared all 26 repaired files to backup: file sizes unchanged; DFF changes
  confined to outer chunk length, TXD changes confined to its width field.

Re-run local checks from this resource directory:

```text
powershell -NoProfile -File tools/check_lua.ps1
python tools/repair_asset_headers.py
```

The Python tool is read-only by default. `--apply` backs up affected files in a
ZIP before repairing known, validated header defects. It is not a full GTA model
compatibility validator.

## Ingame verification

Close any VMM preview before restarting the resource. In F8:

```text
restart vehicle_mod_manager
debugscript 3
vmm
```

Test a previously failing car, especially #024 Gorex, #003 Asiimov Zebra and the
Itasha variants. Test preview, activate, switch to another car and restore the
original. New failure messages include `[VMM]`, the mod ID and the failed step.
No GTA restart or cache deletion should be needed because repaired assets have
new hashes. The resource was not restarted automatically during editing.

The existing `editor_test/music.lua` stack overflow and `killmessages` icon
error belong to other resources and were not modified.

Backups: `tools/backups/before-loading-fixes-20260930-113945.zip` contains the
original Lua files and model/texture assets. A separate `asset-headers-*.zip`
contains just the 26 assets repaired by the utility. Original download ZIPs
also remain available.

References:

- https://wiki.multitheftauto.com/wiki/EngineLoadDFF
- https://wiki.preview.multitheftauto.com/reference/engineReplaceCOL
- https://learn.microsoft.com/en-us/windows/win32/direct3d9/compressed-texture-formats
- https://github.com/microsoft/DirectXTex/wiki/Compress
