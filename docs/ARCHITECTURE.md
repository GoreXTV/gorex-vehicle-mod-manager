# Architecture

## Runtime

The resource is split into shared, server and client responsibilities:

- `config.lua` — shared configuration
- `shared.lua` — shared helpers/data structures
- `server.lua` — library indexing, permissions and asset delivery
- `client.lua` — model/texture application, caching and client-side state
- `gui.lua` — user interface and preview workflow
- `shaders/replace.fx` — texture replacement support

## Asset flow

1. Server scans `mods/` and creates an index.
2. Client requests an asset when a user previews or activates a mod.
3. Server validates that the requested file belongs to the indexed library.
4. The file is transferred with MTA latent events.
5. Client verifies the asset hash and stores it in its local cache.
6. The selected model or texture is applied without restarting MTA.

## Important distinction

The manager is a resource and the mod library is content. Keeping those concepts separate makes the software easier to distribute and allows users to maintain their own private collections.
