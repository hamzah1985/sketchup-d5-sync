import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bogdan_d5_sync'))
from d5_bridge import Bridge, cube_scene

class SettingsBridgeTests(unittest.TestCase):
    def test_authorized_shared_texture_folder_and_opacity_export(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            document = root / 'source.skp'
            document.write_bytes(b'offline path fixture')
            textures = root / 'shared'
            textures.mkdir()
            image = textures / 'checker.png'
            shutil.copy2(Path(__file__).resolve().parents[1] / 'scripts/checker.png', image)
            scene = cube_scene()
            scene.update(document_path=str(document), texture_folder=str(textures), opacity_mode='sketchup')
            scene['materials'][0].update(diffuse_map=str(image), alpha=0.4)
            bridge = Bridge(document, texture_folder=textures)
            try:
                self.assertEqual(bridge.snapshot(scene)['native_instances'], 1)
                path = root / 'opacity.d5a'
                self.assertTrue(bridge.export(path)['export_success'])
                with zipfile.ZipFile(path) as archive:
                    xml = archive.read('d5material.xml').decode('utf8')
                    self.assertIn('<Opacity-->0.6</Opacity-->', xml)
                    self.assertIn('/Base_2/m.m', xml)
                scene['materials'][0]['alpha'] = float('nan')
                with self.assertRaises(ValueError):
                    bridge.snapshot(scene)
            finally:
                bridge.close()
            scene['materials'][0]['alpha'] = 1
            bridge = Bridge(document)
            try:
                with self.assertRaises(ValueError):
                    bridge.snapshot(scene)
            finally:
                bridge.close()
    def test_invalid_custom_d5_path_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                Bridge(Path(folder)/'test.skp', d5_path=folder)

if __name__ == '__main__':
    unittest.main()
