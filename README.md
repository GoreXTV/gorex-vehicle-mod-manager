# GoreX Vehicle Mod Manager for MTA:SA

> Switch vehicle mods, wheels and backlights in-game — without restarting MTA.

**GoreX Vehicle Mod Manager (VMM)** is a quality-of-life resource for **Multi Theft Auto: San Andreas**, built for players, offline sessions and especially **recorders/content creators** who need to change vehicle visuals quickly while working in-game.

## ✨ What it does

- 🚗 Browse and switch vehicle models in-game
- 🛞 Change wheel packs without restarting
- 💡 Swap backlight textures on demand
- 🔎 Search and filter a local/server mod library
- ⭐ Favorites and recently used mods
- 🎥 Creator Mode for rapid mod switching with hotkeys
- 🎨 3D preview with rotation, zoom and multiple lighting presets
- 📸 Automatic preview snapshots
- ⚡ Client-side caching to avoid unnecessary downloads
- 📡 MTA latent-event streaming for large assets
- 🔐 Separate local and global permissions
- 🔄 Rescan the library without restarting the resource
- 🧰 Python tools for importing, validating and repairing assets

## 🎥 Why?

Changing a large collection of GTA:SA mods normally means replacing files, restarting the game and repeating the process whenever you want another look.

VMM is designed to remove that workflow entirely:

**Open → preview → activate → keep recording.**

This is particularly useful for MTA:SA mapping, video production, showcases, testing and offline/freeplay sessions.

## 📦 Requirements

- MTA:SA **1.6.0 r22470 or newer**
- Server-side resource installation
- Python 3 is optional and only required for the included asset tools

## 🚀 Installation

Copy the resource into:

```text
mods/deathmatch/resources/vehicle_mod_manager/
```

Then run in the server console:

```text
refresh
start vehicle_mod_manager
```

Open the manager with:

```text
/vmm
```

The default keyboard shortcut is **F5**.

> In the MTA Map Editor, use `/vmm` instead of F5 because F5 is also used by the editor's test mode.

## 🎮 Controls

| Action | Control |
|---|---|
| Open / close panel | `/vmm`, F5, Esc |
| Preview a mod | Click a mod card |
| Activate | `ACTIVATE` in the preview/panel |
| Rotate preview | Mouse drag |
| Zoom preview | Mouse wheel |
| Preview views | `1`–`5` |
| Favorite | Star / `F` |
| Creator Mode | `/vmm creator` |
| Next mod | `PgDn` |
| Previous mod | `PgUp` |
| Restore original | `End` |
| Rescan library | `RESCAN` / `/vmm rescan` |
| Clear client cache | `/vmm clearcache` |

## 🧑‍🎨 Creator Mode

Creator Mode is intended for people recording videos or testing many variants quickly.

Instead of opening the full UI for every change, use:

```text
/vmm creator
```

Then cycle through the current category with:

```text
PgUp / PgDn
```

and restore the original model with:

```text
End
```

When favorites exist, VMM can optionally cycle only through those favorites.

## 🔒 Permissions

By default, the local panel can be made available to everyone while global changes remain protected.

The relevant settings are in `config.lua`:

```lua
Config.Permission = {
    publicUse    = true,
    use          = "command.vehiclemod",
    global       = "command.vehiclemod_global",
    groups       = { "Admin", "Mapper", "Creator" },
    globalGroups = { "Admin" },
}
```

### LOCAL

A local activation changes the selected visual only for the current client.

### GLOBAL

A global activation changes the selected model for everyone and requires the configured global permission.

## 📁 Adding mods

The manager uses a simple folder-based library:

```text
mods/
├── infernus/
│   └── my_infernus/
│       ├── infernus.dff
│       ├── infernus.txd
│       ├── preview.jpg
│       └── mod.json
├── wheels/
├── backlights/
└── vehicles/
```

Example `mod.json`:

```json
{
  "name": "My Infernus",
  "author": "YourName",
  "description": "My custom Infernus",
  "tags": ["clean", "racing"],
  "models": [411],
  "dff": "infernus.dff",
  "txd": "infernus.txd"
}
```

You can also add `preview.jpg` or `preview.png`. If no preview exists, the built-in snapshot system can generate one.

### Python importer

```text
python tools/import_mod.py --help
```

For example:

```text
python tools/import_mod.py --gui
```

The included tools can also validate DFF files, repair asset headers and normalize Infernus collision files.

## ⚠️ Mod assets and copyright

This repository contains the **Vehicle Mod Manager software**, not a redistribution license for third-party GTA:SA vehicle assets.

Only upload `.dff`, `.txd`, `.col`, texture and preview assets to your public repository when you have permission to redistribute them.

The repository intentionally ships with empty category folders so the manager can be used with your own or properly licensed mod library.

If you redistribute a mod created by someone else, keep the original creator information and follow their stated license/permission requirements.

## 🧪 Development checks

Python tests:

```text
python -m unittest discover -s tools -p "test_*.py"
```

Lua checks:

```powershell
powershell -NoProfile -File tools/check_lua.ps1
```

Asset audits:

```text
python tools/repair_asset_headers.py
python tools/normalize_infernus_collision.py
```

The repair commands are read-only unless `--apply` is explicitly supplied.

## 🗂️ Project structure

```text
vehicle_mod_manager/
├── client.lua
├── server.lua
├── shared.lua
├── gui.lua
├── config.lua
├── meta.xml
├── shaders/
├── mods/                 # Your mod library
├── tools/                # Importers and validation tools
├── assets/               # Resource documentation/assets
├── docs/                 # Additional documentation
├── tests/                # Optional project tests
├── .github/              # GitHub issue templates/workflows
├── .gitignore
├── LICENSE
├── CHANGELOG.md
└── CONTRIBUTING.md
```

## 🛣️ Roadmap

- [ ] More mod categories
- [ ] Better library management
- [ ] Drag-and-drop mod importing
- [ ] More preview environments
- [ ] Improved creator workflow
- [ ] Optional mod metadata editor
- [ ] GitHub release packages
- [ ] Optional community mod library

## 🤝 Contributing

Bug reports, suggestions and pull requests are welcome.

Before submitting a pull request:

1. Keep changes focused.
2. Test the resource in MTA:SA.
3. Run the available offline checks.
4. Do not add third-party mod assets without redistribution permission.
5. Update the documentation when behavior or configuration changes.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

The VMM source code is released under the MIT License. See [LICENSE](LICENSE).

**Third-party mod assets are not automatically covered by the source-code license.**

## 👤 Author

**GoreX**

Built for the MTA:SA community, recorders, creators and anyone who wants to experiment with vehicle visuals without constantly restarting the game.
