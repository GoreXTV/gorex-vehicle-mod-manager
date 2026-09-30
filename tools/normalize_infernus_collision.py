"""Use the stock model-411 collision in every Infernus DFF and sidecar COL.

Dry-run by default. --apply creates a backup ZIP before modifying the library.
The collision must stay embedded: engineReplaceCOL does not support vehicles.
"""
import argparse
from datetime import datetime
from pathlib import Path
import struct
import zipfile

from repair_asset_headers import chunks, repair_dff, validate_tree

ROOT = Path(__file__).resolve().parents[1]
STANDARD = ROOT / 'assets' / 'infernus_standard.col'
COLLISION_PLUGIN = 0x253F2FA


def read_standard():
    data = STANDARD.read_bytes()
    if data[:4] != b'COL3' or struct.unpack_from('<I', data, 4)[0] + 8 != len(data):
        raise ValueError('Invalid standard Infernus collision')
    if data[8:30].split(b'\0')[0].lower() not in (b'infernus', b'infernus_col'):
        raise ValueError('Collision does not belong to the stock Infernus')
    return data


def pack_chunk(kind, payload, version):
    return struct.pack('<III', kind, len(payload), version) + payload


def embedded_collisions(data):
    result = []
    end = 12 + struct.unpack_from('<I', data, 4)[0]
    for kind, begin, stop in chunks(data, 12, end):
        if kind == 3:
            for plugin, start, finish in chunks(data, begin, stop):
                if plugin == COLLISION_PLUGIN:
                    result.append(data[start:finish])
    return result


def normalize_dff(original, standard):
    data, _ = repair_dff(original)
    end = 12 + struct.unpack_from('<I', data, 4)[0]
    result = []
    found = 0
    for kind, begin, stop in chunks(data, 12, end):
        version = struct.unpack_from('<I', data, begin - 4)[0]
        if kind == 3:
            plugins = []
            for plugin, start, finish in chunks(data, begin, stop):
                if plugin == COLLISION_PLUGIN:
                    plugin_version = struct.unpack_from('<I', data, start - 4)[0]
                    plugins.append(pack_chunk(plugin, standard, plugin_version))
                    found += 1
                else:
                    plugins.append(data[start - 12:finish])
            result.append(pack_chunk(kind, b''.join(plugins), version))
        else:
            result.append(data[begin - 12:stop])
    if found != 1:
        raise ValueError(f'Expected one embedded vehicle collision, found {found}')
    version = struct.unpack_from('<I', data, 8)[0]
    updated = pack_chunk(0x10, b''.join(result), version) + data[end:]
    validate_tree(updated, 12, 12 + struct.unpack_from('<I', updated, 4)[0])
    assert embedded_collisions(updated) == [standard]
    return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    standard = read_standard()
    pending, count = [], 0
    for path in sorted((ROOT / 'mods' / 'infernus').rglob('*')):
        if path.suffix.lower() not in ('.dff', '.col'):
            continue
        original = path.read_bytes()
        updated = normalize_dff(original, standard) if path.suffix.lower() == '.dff' else standard
        count += 1
        if original != updated:
            pending.append((path, original, updated))
    if args.apply and pending:
        backup_dir = ROOT / 'tools' / 'backups'
        backup_dir.mkdir(exist_ok=True)
        backup = backup_dir / ('before-standard-collision-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.zip')
        with zipfile.ZipFile(backup, 'x', zipfile.ZIP_DEFLATED) as archive:
            for path, original, _ in pending:
                archive.writestr(path.relative_to(ROOT).as_posix(), original)
        for path, _, updated in pending:
            path.write_bytes(updated)
        print('Backup:', backup)
    print(f'{count} DFF/COL files checked; {len(pending)} ' + ('normalized' if args.apply else 'need normalization'))


if __name__ == '__main__':
    main()
