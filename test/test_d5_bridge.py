# SPDX-License-Identifier: GPL-3.0-or-later
"""Native offline integration checks; these do not certify live D5 rendering."""
import copy
import itertools
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bogdan_d5_sync'))

from d5_bridge import Bridge, cube_scene, triangle_buffers, transform_array, camera_values


class BridgeTests(unittest.TestCase):
    def _read_native_triangle(self, path, source_points):
        """Read one actual serialized triangle, its per-corner data and frame."""
        import numpy as np
        with zipfile.ZipFile(path) as archive:
            data = archive.read('1.d5mesh')
            info = json.loads(archive.read('info.json'))
        self.assertEqual(struct.unpack_from('<I',data)[0],11,
                         'Update the parser for this D5 mesh format')
        self.assertEqual(len(info['instanceIdArray']),1)
        node,material = info['instanceIdArray'][0].strip('/').split('/')
        name = (node+'_'+material).encode('utf-16-le')
        offset = data.find(name)
        self.assertGreaterEqual(offset,0)
        offset += len(name)
        chars = struct.unpack_from('<I',data,offset)[0]
        self.assertEqual(data[offset+4:offset+4+chars*2].decode('utf-16-le'),material)
        matrix = np.asarray(struct.unpack_from('<16f',data,offset+4+chars*2)).reshape(4,4).T
        points = np.asarray(source_points,dtype=np.float32)*100
        for order in itertools.permutations(range(3)):
            local = points[list(order)]
            pattern = struct.pack('<9f',*local.ravel())
            offset = data.find(pattern)
            if offset < 0:
                continue
            self.assertEqual(struct.unpack_from('<I',data,offset+36)[0],9)
            normals = np.asarray(struct.unpack_from('<9f',data,offset+40)).reshape(3,3)
            self.assertEqual(struct.unpack_from('<I',data,offset+76)[0],6)
            uvs = np.asarray(struct.unpack_from('<6f',data,offset+80)).reshape(3,2)
            world = local @ matrix[:3,:3].T + matrix[:3,3]
            world_normals = normals @ np.linalg.inv(matrix[:3,:3])
            world_normals /= np.linalg.norm(world_normals,axis=1)[:,None]
            return {'matrix':matrix,'local':local,'world':world,
                    'normals':world_normals,'uvs':uvs,'order':order}
        self.fail('Expected source-axis triangle was not serialized by the Blender route')

    def test_degenerate_triangles_keep_valid_normals_and_uvs_aligned(self):
        import numpy as np
        obj = {'vertices': [[0,0,0],[1,0,0],[2,0,0],[0,1,0]],
               'triangles': [[0,1,2],[0,1,3],[1,1,3]],
               'normals': [[0,0,1],[0,0,1],[1,0,0],[0,1,1]],
               'uvs': [[0,0],[1,0],[2,0],[0,1]]}
        stats = {'skipped_degenerate_triangles': 0}
        coords, normals, loops, _, uvs, polygons, materials = triangle_buffers(obj, stats)
        self.assertEqual(stats['skipped_degenerate_triangles'], 2)
        self.assertTrue(np.array_equal(coords.reshape(-1,3), [[0,0,0],[1,0,0],[0,1,0]]))
        self.assertTrue(np.allclose(normals.reshape(-1,3), [[0,0,1],[0,0,1],[0,2**-0.5,2**-0.5]]))
        self.assertTrue(np.array_equal(uvs.reshape(-1,2), [[0,0],[1,0],[0,1]]))
        self.assertEqual((len(loops),len(polygons),len(materials)), (3,1,1))

    def test_float32_collapsed_triangle_does_not_abort_other_geometry(self):
        obj = {'vertices': [[100000000,0,0],[100000000.01,0,0],[100000000,1,0],
                            [0,0,0],[1,0,0],[0,1,0]],
               'triangles': [[0,1,2],[3,4,5]]}
        buffers = triangle_buffers(obj)
        self.assertEqual(len(buffers[0]), 9)

    def test_all_degenerate_object_is_removed_and_can_reappear(self):
        scene = cube_scene()
        self.bridge.snapshot(scene)
        degenerate = copy.deepcopy(scene)
        degenerate['objects'][0]['triangles'] = [[0,0,0]]
        result = self.bridge.snapshot(degenerate)
        self.assertEqual(result['skipped_degenerate_triangles'], 1)
        self.assertEqual(result['native_instances'], 0)
        self.assertEqual(self.bridge.snapshot(scene)['native_instances'], 1)

    def test_mixed_valid_and_degenerate_native_snapshot_still_exports(self):
        scene = cube_scene()
        scene['objects'][0]['triangles'].append([0,0,0])
        result = self.bridge.snapshot(scene)
        self.assertEqual(result['skipped_degenerate_triangles'], 1)
        self.assertEqual(result['native_instances'], 1)
        self.assertTrue(self.bridge.export(self.root / 'filtered.d5a')['export_success'])

    def test_nonfinite_source_is_not_silently_filtered(self):
        scene = cube_scene()
        self.bridge.snapshot(scene)
        previous = dict(self.bridge.hashes)
        scene['objects'][0]['vertices'][0][0] = float('nan')
        with self.assertRaisesRegex(ValueError, 'finite'):
            self.bridge.snapshot(scene)
        self.assertEqual(self.bridge.hashes, previous)

    def test_camera_axes_units_fov_and_projection_dispatch(self):
        from unittest.mock import Mock
        camera = {'position':[1,2,3], 'forward':[0,2,0], 'up':[0,0,1],
                  'horizontal_fov':60, 'orthographic':False, 'orthographic_width':4.5}
        transform, fov, width = camera_values(camera)
        self.assertEqual(transform, [200,100,300,1,0,0,0,0,1])
        self.assertEqual((fov,width), (60,450))
        fake = Bridge.__new__(Bridge)
        fake.session = object()
        fake.d = Mock()
        fake.send_camera(camera)
        fake.d.SendCameraTransformFov.assert_called_once_with(fake.session, transform,60)
        camera['orthographic'] = True
        fake.send_camera(camera)
        fake.d.D5SendCamera.assert_called_once_with(fake.session)
        fake.d.D5SetEntityFloatProperty.assert_called_with(
            fake.session,fake.d.ET_CAMERA,'','orthogonal_width',450)
        fake.session = None

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bridge = Bridge(self.root / 'source.skp')

    def tearDown(self):
        self.bridge.close()
        self.tmp.cleanup()

    def test_native_fractional_geometry_and_material_export(self):
        scene = cube_scene(size=1.25, color='#2B88D8')
        self.bridge.snapshot(scene)
        path = self.root / 'cube.d5a'
        self.assertTrue(self.bridge.export(path)['export_success'])
        with zipfile.ZipFile(path) as archive:
            mesh = archive.read('1.d5mesh')
            # Three consecutive triangle vertices in centimetres. Verifies
            # fractional metre coordinates survived the native API binding.
            # Blender submission retains source axes in the mesh and carries
            # the D5 conversion on its native instance transform.
            points = [[0,0,0],[125,125,0],[125,0,0]]
            # Match the vendor's final world-space winding after reflection.
            points.reverse()
            rotations = [points[i:]+points[:i] for i in range(3)]
            patterns = [struct.pack('<9f', *[v for p in tri for v in p]) for tri in rotations]
            self.assertTrue(any(pattern in mesh for pattern in patterns))
            material = archive.read('d5material.xml').decode('utf8')
            self.assertIn('2B88D8', material)
        self.assertNotIn('bpy', sys.modules)

    def test_native_default_material_exports_white(self):
        scene = cube_scene()
        scene['materials'] = []
        scene['objects'][0].pop('material_id')
        self.bridge.snapshot(scene)
        path = self.root / 'default-white.d5a'
        self.assertTrue(self.bridge.export(path)['export_success'])
        with zipfile.ZipFile(path) as archive:
            material = archive.read('d5material.xml').decode('utf8')
            self.assertIn('FFFFFF', material)
            self.assertNotIn('CCCCCC', material)
            self.assertIn('<Metallic>0</Metallic>', material)
            self.assertIn('<Specular>0.5</Specular>', material)

    def test_incremental_noop_move_resize_material_delete_restore(self):
        first = self.bridge.snapshot(cube_scene())
        self.assertEqual(first['changed'], 1)
        self.assertEqual(first['native_instances'], 1)
        self.assertEqual(self.bridge.snapshot(cube_scene())['changed'], 0)
        moved = self.bridge.snapshot(cube_scene(x=2.25))
        self.assertEqual(moved['changed'], 1)
        self.assertEqual(moved['native_instances'], 1)
        resized = self.bridge.snapshot(cube_scene(x=2.25, size=1.5))
        self.assertEqual(resized['changed'], 1)
        self.assertEqual(resized['native_instances'], 1)
        result = self.bridge.snapshot(cube_scene(x=2.25, size=1.5, color='#112233'))
        self.assertEqual(result['changed'], 0)
        self.assertEqual(result['materials_changed'], 1)
        deleted = self.bridge.snapshot({'objects': []})
        self.assertEqual(deleted['removed'], 1)
        self.assertEqual(deleted['native_instances'], 0)
        self.assertEqual(self.bridge.snapshot(cube_scene())['changed'], 1)

    def test_invalid_snapshot_does_not_erase_acknowledged_scene(self):
        self.bridge.snapshot(cube_scene())
        previous = dict(self.bridge.hashes)
        scene = cube_scene()
        scene['objects'][0]['triangles'][0][0] = 999
        with self.assertRaisesRegex(ValueError, 'outside vertex'):
            self.bridge.snapshot(scene)
        self.assertEqual(self.bridge.hashes, previous)

    def test_source_ids_are_isolated(self):
        other = Bridge(self.root / 'other.skp')
        try:
            self.assertNotEqual(self.bridge.identifier('node', 'a'), other.identifier('node', 'a'))
        finally:
            other.close()

    def test_d5_transform_conversion(self):
        matrix = [[1,0,0,2.25],[0,1,0,3.5],[0,0,1,4.75],[0,0,0,1]]
        self.assertEqual(transform_array(matrix),
                         [1,0,0,0,0,1,0,0,0,0,1,0,225,350,475,1])

    def test_mesh_axes_normals_and_clockwise_winding_agree(self):
        import numpy as np
        obj = {'vertices':[[0,0,0],[2,0,0],[0,0,1]], 'triangles':[[0,1,2]]}
        coords, normals, *_ = triangle_buffers(obj)
        points = coords.reshape(-1,3)
        self.assertEqual(points.tolist(), [[0,0,0],[2,0,0],[0,0,1]])
        self.assertEqual(normals.reshape(-1,3).tolist(), [[0,-1,0]]*3)
        # Input stays right-handed; the native SDK handles conversion.
        cross = np.cross(points[1]-points[0], points[2]-points[0])
        self.assertGreater(float(np.dot(cross, normals[:3])), 0)

    def test_supplied_smooth_normals_survive_axes_mapping_and_native_export(self):
        import numpy as np
        obj = {'id':'curved', 'vertices':[[0,0,0],[2,0,0],[0,0,1]],
               'triangles':[[0,1,2]], 'normals':[[0,-1,1],[0,-1,1],[0,-1,0]]}
        _, normals, *_ = triangle_buffers(obj)
        expected = [[0,-1/2**.5,1/2**.5],[0,-1/2**.5,1/2**.5],[0,-1,0]]
        self.assertTrue(np.allclose(normals.reshape(-1,3),expected))
        self.bridge.snapshot({'objects':[obj]})
        path = self.root/'smooth-normals.d5a'
        self.assertTrue(self.bridge.export(path)['export_success'])
        native = self._read_native_triangle(path,obj['vertices'])
        expected_world = np.asarray(expected)[:,[1,0,2]][list(native['order'])]
        self.assertTrue(np.allclose(native['normals'],expected_world,atol=1e-6))
        previous = dict(self.bridge.hashes)
        obj['normals'][0] = [0,0,0]
        with self.assertRaisesRegex(ValueError,'nonzero'):
            self.bridge.snapshot({'objects':[obj]})
        self.assertEqual(self.bridge.hashes,previous)
        obj['normals'] = [[0,0,1]]
        with self.assertRaisesRegex(ValueError,'one per vertex'):
            triangle_buffers(obj)

    def test_rotated_group_world_position_matches_camera_axes_without_mirroring(self):
        import numpy as np
        source = [[0,-1,0,2],[1,0,0,3],[0,0,1,4],[0,0,0,1]]
        converted = np.array(transform_array(source)).reshape(4,4).T
        # SDK input stays in source axes; native export checks conversion below.
        point = converted @ np.array([100,200,300,1])
        self.assertTrue(np.allclose(point, [0,400,700,1]))
        self.assertAlmostEqual(float(np.linalg.det(converted[:3,:3])), 1)

    def test_stdio_protocol_with_real_native_module(self):
        worker = Path(__file__).resolve().parents[1] / 'bogdan_d5_sync/d5_bridge.py'
        requests = [{'op': 'info'}, {'op': 'snapshot', 'scene': cube_scene(size=1.25)},
                    {'op': 'export', 'path': str(self.root / 'stdio.d5a')}, {'op': 'quit'}]
        result = subprocess.run([sys.executable, str(worker), '--stdio', '--source',
                                 str(self.root / 'stdio.skp'), '--output', str(self.root / 'worker.json')],
                                input=''.join(json.dumps(r)+'\n' for r in requests),
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([r['op'] for r in replies], ['info', 'snapshot', 'export'])
        self.assertTrue(all(r['ok'] for r in replies))
        self.assertFalse(replies[0]['blender_imported'])
        self.assertTrue(replies[2]['export_success'])

    def test_native_output_places_rotated_mesh_in_the_camera_coordinate_frame(self):
        import numpy as np
        obj = {'id':'native-frame-check', 'vertices':[[1,2,3],[4,5,6],[7,8,11]],
               'triangles':[[0,1,2]], 'material_id':'probe',
               'transform':[[0,-1,0,2],[1,0,0,3],[0,0,1,4],[0,0,0,1]]}
        self.bridge.snapshot({'objects':[obj], 'materials':[{'id':'probe','color':'#FFFFFF'}]})
        path = self.root/'native-coordinate-frame.d5a'
        self.assertTrue(self.bridge.export(path)['export_success'])
        native = self._read_native_triangle(path,obj['vertices'])
        swap = np.array([[0,1,0,0],[1,0,0,0],[0,0,1,0],[0,0,0,1]])
        source = np.asarray(obj['transform'],dtype=float)
        source[:3,3] *= 100
        expected = np.asarray(obj['vertices'])*100 @ (swap@source)[:3,:3].T + (swap@source)[:3,3]
        self.assertTrue(np.allclose(native['world'],expected[list(native['order'])],atol=5e-4))
        # The Blender route's reflected instance plus source-axis vertices is
        # significant: the generic Max route was position-correct but rendered black.
        self.assertTrue(np.allclose(native['matrix'],swap@source,atol=2e-5))
        self.assertLess(float(np.linalg.det(native['matrix'][:3,:3])),0)
        camera, _, _ = camera_values({'position':[0,4,7], 'forward':[0,1,0],
                                     'up':[0,0,1], 'horizontal_fov':60})
        first = list(native['order']).index(0)
        self.assertTrue(np.allclose(native['world'][first],camera[:3],atol=5e-4))

    def test_native_front_face_winding_agrees_with_outward_normals(self):
        import numpy as np
        obj = {'id':'front-face', 'vertices':[[1,2,3],[4,6,7],[8,5,11]],
               'triangles':[[0,1,2]]}
        self.bridge.snapshot({'objects':[obj]})
        path = self.root/'front-face.d5a'
        self.assertTrue(self.bridge.export(path)['export_success'])
        actual = self._read_native_triangle(path,obj['vertices'])
        # Reference the vendor's Blender path, including its column-swapped
        # transform. A cross-product sign guessed from handedness missed this.
        reference = Bridge(self.root/'vendor-reference.blend')
        try:
            d, s = reference.d, reference.session
            d.D5SetSceneSettings(s,1.,d.Handness.RightZUp,d.FaceClockwise.CW)
            material = reference.identifier('material','probe')
            d.D5AddMaterial(s,material)
            d.D5SetMaterialType(s,material,d.D5MaterialType.MT_CUSTOM)
            coords,normals,loops,vertices,uvs,polys,materials = triangle_buffers(obj)
            matrix = transform_array([[0,1,0,0],[1,0,0,0],[0,0,1,0],[0,0,0,1]])
            node = reference.identifier('node','reference') + '0'*32
            d.BlenderAddNode(s,node,node,matrix,[material],loops,vertices,coords,
                            normals,uvs,polys,materials,100.,True)
            vendor_path = self.root/'vendor-reference.d5a'
            self.assertTrue(reference.export(vendor_path)['export_success'])
            expected = self._read_native_triangle(vendor_path,obj['vertices'])
        finally:
            reference.close()
        def facing(native):
            world = native['world']
            return float(np.dot(np.cross(world[1]-world[0],world[2]-world[0]),native['normals'][0]))
        actual_facing,expected_facing = facing(actual),facing(expected)
        self.assertGreater(expected_facing,0)
        self.assertGreater(actual_facing,0,'Native world-space face orientation differs from the vendor connector')
        self.assertTrue(np.allclose(actual['world'],expected['world'],atol=5e-4))
        self.assertTrue(np.allclose(actual['normals'],expected['normals'],atol=1e-6))

    def test_native_reflected_nonuniform_mesh_preserves_world_pose_and_normals(self):
        import numpy as np
        obj = {'id':'reflected-frame','vertices':[[1,2,3],[4,6,7],[8,5,11]],
               'triangles':[[0,1,2]],
               'transform':[[0,2,0,2],[.5,0,0,3],[0,0,1.7,4],[0,0,0,1]]}
        points = np.asarray(obj['vertices'],dtype=float)
        normal = np.cross(points[1]-points[0],points[2]-points[0])
        normal /= np.linalg.norm(normal)
        obj['normals'] = [normal.tolist()]*3
        self.bridge.snapshot({'objects':[obj]})
        path = self.root/'reflected-frame.d5a'
        self.assertTrue(self.bridge.export(path)['export_success'])
        native = self._read_native_triangle(path,obj['vertices'])
        source = np.asarray(obj['transform'],dtype=float)
        swap = np.asarray([[0,1,0],[1,0,0],[0,0,1]])
        expected = (points@source[:3,:3].T + source[:3,3]) @ swap * 100
        self.assertTrue(np.allclose(native['world'],expected[list(native['order'])],atol=5e-4))
        expected_normal = np.linalg.inv(swap@source[:3,:3]).T @ normal
        expected_normal /= np.linalg.norm(expected_normal)
        self.assertTrue(np.allclose(native['normals'],[expected_normal]*3,atol=1e-6))
        # Follow the vendor's local CW loop contract; reflected-instance
        # culling belongs to the renderer, not an assumed world cross-product sign.
        self.assertEqual(native['order'],(2,1,0))

    def test_native_asymmetric_uvs_keep_source_orientation_and_vertex_alignment(self):
        import numpy as np
        obj = {'id':'uv-orientation','vertices':[[1,2,3],[4,6,7],[8,5,11]],
               'triangles':[[0,1,2]], 'uvs':[[.125,.2],[1.3,.4],[.77,1.6]]}
        self.bridge.snapshot({'objects':[obj]})
        path = self.root/'uv-orientation.d5a'
        self.assertTrue(self.bridge.export(path)['export_success'])
        native = self._read_native_triangle(path,obj['vertices'])
        expected = np.asarray(obj['uvs'])[list(native['order'])]
        self.assertTrue(np.allclose(native['uvs'],expected,atol=2e-7),
                        'The Blender SDK V flip must be compensated without swapping vertex UVs')


if __name__ == '__main__':
    unittest.main()
