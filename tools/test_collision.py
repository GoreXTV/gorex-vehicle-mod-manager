from pathlib import Path
import struct
import tempfile
import unittest

from import_mod import import_one
from normalize_infernus_collision import (
    ROOT, COLLISION_PLUGIN, embedded_collisions, normalize_dff, pack_chunk, read_standard,
)

VERSION = 0x1803FFFF


def sample(collision=b'old collision', duplicate=False):
    geometry = pack_chunk(1, b'geometry sentinel', VERSION)
    plugin = pack_chunk(COLLISION_PLUGIN, collision, VERSION)
    extension = pack_chunk(3, plugin * (2 if duplicate else 1), VERSION)
    return pack_chunk(0x10, geometry + extension, VERSION) + b'\0' * 64


class CollisionTests(unittest.TestCase):
    def test_changes_only_collision_and_parent_lengths(self):
        original = sample()
        standard = read_standard()
        result = normalize_dff(original, standard)
        self.assertEqual(embedded_collisions(result), [standard])
        self.assertEqual(result[12:41], original[12:41])
        self.assertEqual(result[-64:], original[-64:])
        self.assertEqual(len(result) - len(original), len(standard) - len(b'old collision'))
        self.assertEqual(normalize_dff(result, standard), result)

    def test_rejects_ambiguous_or_truncated_inputs(self):
        with self.assertRaises(ValueError):
            normalize_dff(sample(duplicate=True), read_standard())
        with self.assertRaises(ValueError):
            normalize_dff(sample()[:30], read_standard())

    def test_all_bundled_infernus_collisions_match(self):
        paths = list((ROOT / 'mods/infernus').rglob('*.dff'))
        if not paths:
            self.skipTest('Public source distribution does not bundle third-party mod binaries.')
        standard = read_standard()
        for path in paths:
            with self.subTest(path=path.name, mod=path.parent.name):
                self.assertEqual(embedded_collisions(path.read_bytes()), [standard])
        for path in (ROOT / 'mods/infernus').rglob('*.col'):
            self.assertEqual(path.read_bytes(), standard)

    def test_importer_normalizes_and_leaves_source_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source.dff'
            source.write_bytes(sample())
            target = import_one(str(root / 'mods'), 'infernus', 'Test', [str(source)])
            self.assertEqual(embedded_collisions((Path(target) / source.name).read_bytes()), [read_standard()])
            self.assertEqual(source.read_bytes(), sample())

    def test_importer_validates_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source.dff'
            source.write_bytes(sample()[:30])
            with self.assertRaises(ValueError):
                import_one(str(root / 'mods'), 'infernus', 'Bad', [str(source)])
            self.assertFalse((root / 'mods').exists())

    def test_other_vehicle_categories_are_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source.dff'
            source.write_bytes(sample())
            target = import_one(str(root / 'mods'), 'vehicles', 'Other', [str(source)])
            self.assertEqual((Path(target) / source.name).read_bytes(), sample())


if __name__ == '__main__':
    unittest.main()
