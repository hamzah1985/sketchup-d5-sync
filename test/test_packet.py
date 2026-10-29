# SPDX-License-Identifier: GPL-3.0-or-later
import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bogdan_d5_sync'))
import numpy as np
from packet import read_request
from d5_bridge import Bridge, cube_scene, object_fingerprint


class PacketTests(unittest.TestCase):
    def packet(self, scene):
        scene = copy.deepcopy(scene)
        chunks = []
        fields = {'vertices': (3, '<f4'), 'triangles': (3, '<i4'),
                  'normals': (3, '<f4'), 'uvs': (2, '<f4')}
        for obj in scene['objects']:
            for name, (columns, dtype) in fields.items():
                if name in obj:
                    values = np.asarray(obj[name], dtype=dtype).reshape(-1, columns)
                    chunks.append(values.tobytes())
                    obj[name] = {'rows': len(values), 'bytes': len(chunks[-1])}
        header = {'op': 'snapshot', 'mesh_encoding': 'le32-v1',
                  'payload_bytes': sum(map(len, chunks)), 'scene': scene}
        return header, b''.join(chunks)

    def test_ruby_encoder_interoperates_with_python_and_next_camera_frame(self):
        scene = cube_scene(x=3)
        scene['objects'][0]['uvs'] = [[0.1, 0.2]] * 8
        encoder = Path(__file__).resolve().parents[1] / 'bogdan_d5_sync/packet.rb'
        code = 'require ARGV[0]; request=JSON.parse(STDIN.read); STDOUT.binmode; BogdanD5Sync::Packet.encode(request).each { |part| STDOUT.write(part) }'
        result = subprocess.run(['ruby', '-e', code, str(encoder)],
                                input=json.dumps({'op': 'snapshot', 'scene': scene}).encode(),
                                capture_output=True, check=True)
        stream = io.BytesIO(result.stdout + b'{"op":"camera","camera":{}}\n')
        decoded = read_request(stream)
        self.assertEqual(object_fingerprint(decoded['scene']['objects'][0]), object_fingerprint(scene['objects'][0]))
        self.assertEqual(read_request(stream)['op'], 'camera')
        self.assertIsNone(read_request(stream))

    def test_malformed_frame_dimensions_and_truncation_rejected(self):
        header, payload = self.packet(cube_scene())
        for key, value in [('payload_bytes', -1), ('payload_bytes', len(payload)+1), ('mesh_encoding', 'unknown')]:
            altered = dict(header, **{key: value})
            with self.assertRaises(ValueError):
                read_request(io.BytesIO(json.dumps(altered).encode()+b'\n'+payload))
        with self.assertRaises(ValueError):
            read_request(io.BytesIO(json.dumps(header).encode()+b'\n'+payload[:-1]))
        header['scene']['objects'][0]['vertices']['rows'] = True
        with self.assertRaises(ValueError):
            read_request(io.BytesIO(json.dumps(header).encode()+b'\n'+payload))

    def test_binary_and_json_native_exports_match_mesh_and_materials(self):
        import tempfile
        import zipfile
        scene = cube_scene()
        header, payload = self.packet(scene)
        decoded = read_request(io.BytesIO(json.dumps(header).encode()+b'\n'+payload))['scene']
        with tempfile.TemporaryDirectory() as folder:
            bridge = Bridge(Path(folder)/'fixture.skp')
            try:
                bridge.snapshot(scene)
                bridge.export(Path(folder)/'json.d5a')
                bridge.snapshot(decoded)
                bridge.export(Path(folder)/'binary.d5a')
                with zipfile.ZipFile(Path(folder)/'json.d5a') as a, zipfile.ZipFile(Path(folder)/'binary.d5a') as b:
                    for name in ('1.d5mesh', 'd5material.xml'):
                        self.assertEqual(a.read(name), b.read(name), name)
                    info_a, info_b = json.loads(a.read('info.json')), json.loads(b.read('info.json'))
                    # The vendor generates a fresh product GUID per ExportStart.
                    self.assertTrue(info_a.pop('productID'))
                    self.assertTrue(info_b.pop('productID'))
                    self.assertEqual(info_a, info_b)
            finally:
                bridge.close()

    def test_unchanged_live_mesh_skips_conversion_and_keeps_degenerate_diagnostics(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            bridge = Bridge(Path(folder)/'fixture.skp')
            try:
                scene = cube_scene()
                scene['objects'][0]['triangles'].append([0, 0, 0])
                bridge.snapshot(scene)
                bridge.connect_live = True
                with patch('d5_bridge.triangle_buffers', side_effect=AssertionError('unchanged mesh rebuilt')):
                    result = bridge.snapshot(scene)
                self.assertEqual(result['changed'], 0)
                self.assertEqual(result['skipped_degenerate_triangles'], 1)
                malformed = copy.deepcopy(scene)
                malformed['objects'][0]['vertices'][0][0] = float('nan')
                with self.assertRaises(ValueError):
                    bridge.snapshot(malformed)
            finally:
                bridge.connect_live = False
                bridge.close()


if __name__ == '__main__':
    unittest.main()
