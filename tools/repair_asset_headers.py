"""Audit known library header defects; --apply repairs after making a ZIP backup.

Only fixes complete DFF clumps whose length wrongly includes their own header,
and single-level D3D9 DXT textures whose stored blocks already cover the rounded
dimensions. Geometry and compressed pixel bytes are never changed.
"""
import argparse
from datetime import datetime
from pathlib import Path
import struct
import zipfile

CONTAINERS = {0x10, 0x0E, 0x1A, 0x0F, 0x08, 0x07, 0x06, 0x03, 0x14}


def chunks(data, start, end):
    while start < end:
        if start + 12 > end:
            raise ValueError(f"Incomplete chunk header at {start}")
        kind, size, version = struct.unpack_from('<III', data, start)
        stop = start + 12 + size
        if stop > end:
            raise ValueError(f"Chunk {kind:#x} at {start} exceeds its parent")
        yield kind, start + 12, stop
        start = stop


def validate_tree(data, start, end):
    for kind, begin, stop in chunks(data, start, end):
        if kind in CONTAINERS:
            validate_tree(data, begin, stop)


def repair_dff(original):
    data = bytearray(original)
    kind, size, _ = struct.unpack_from('<III', data)
    if kind != 0x10:
        raise ValueError('Expected a DFF clump')
    changes = []
    if size == len(data):
        # Validate all children before accepting the exact 12-byte correction.
        validate_tree(data, 12, len(data))
        struct.pack_into('<I', data, 4, size - 12)
        changes.append(f'clump payload length {size} -> {size - 12}')
    elif size + 12 > len(data):
        raise ValueError('Truncated DFF; not a known header-only defect')
    validate_tree(data, 12, 12 + struct.unpack_from('<I', data, 4)[0])
    return bytes(data), changes


def repair_txd(original):
    data = bytearray(original)
    kind, size, _ = struct.unpack_from('<III', data)
    if kind != 0x16 or size + 12 > len(data):
        raise ValueError('Invalid texture dictionary')
    changes = []
    for kind, begin, end in chunks(data, 12, 12 + size):
        if kind != 0x15:
            continue
        for kind, begin, end in chunks(data, begin, end):
            if kind != 1:
                continue
            if end - begin < 92:
                raise ValueError('Incomplete native texture')
            platform = struct.unpack_from('<I', data, begin)[0]
            fmt = bytes(data[begin + 76:begin + 80])
            if platform != 9 or fmt not in (b'DXT1', b'DXT2', b'DXT3', b'DXT4', b'DXT5'):
                continue
            w, h, depth, mips = struct.unpack_from('<HHBB', data, begin + 80)
            if not w or not h:
                raise ValueError('Zero texture dimension')
            cursor = begin + 88
            for level in range(mips):
                if cursor + 4 > end:
                    raise ValueError('Missing mip length')
                length = struct.unpack_from('<I', data, cursor)[0]
                expected = ((max(1, w >> level) + 3) // 4) * ((max(1, h >> level) + 3) // 4) * (8 if fmt == b'DXT1' else 16)
                if length != expected or cursor + 4 + length > end:
                    raise ValueError('DXT mip data size mismatch')
                cursor += 4 + length
            if w % 4 or h % 4:
                if mips != 1 or w < 4 or h < 4:
                    raise ValueError('Unaligned texture requires a full re-export')
                nw, nh = (w + 3) // 4 * 4, (h + 3) // 4 * 4
                struct.pack_into('<HH', data, begin + 80, nw, nh)
                name = data[begin + 8:begin + 40].split(b'\0')[0].decode('latin1')
                changes.append(f'{name}: {w}x{h} -> {nw}x{nh} (existing edge padding)')
    return bytes(data), changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    pending = []
    checked = 0
    for path in sorted((root / 'mods').rglob('*')):
        if path.suffix.lower() not in ('.dff', '.txd'):
            continue
        original = path.read_bytes()
        repair = repair_dff if path.suffix.lower() == '.dff' else repair_txd
        updated, changes = repair(original)
        checked += 1
        if changes:
            assert not repair(updated)[1], 'Repair must be idempotent'
            pending.append((path, original, updated))
            print(path.relative_to(root), '; '.join(changes))
    if args.apply and pending:
        backups = root / 'tools' / 'backups'
        backups.mkdir(exist_ok=True)
        backup = backups / ('asset-headers-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.zip')
        with zipfile.ZipFile(backup, 'x', zipfile.ZIP_DEFLATED) as archive:
            for path, original, _ in pending:
                archive.writestr(path.relative_to(root).as_posix(), original)
        for path, _, updated in pending:
            path.write_bytes(updated)
            assert path.read_bytes() == updated
        print('Backup:', backup)
    print(f'{checked} assets checked; {len(pending)} files ' + ('repaired' if args.apply else 'need repair'))


if __name__ == '__main__':
    main()
