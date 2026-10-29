# SPDX-License-Identifier: GPL-3.0-or-later
"""Experimental local bridge using the user's installed D5 Blender connector.

No Blender import or process is required. Run with Blender's matching standalone
Python (3.13 for this machine). Vendor modules are located, never redistributed.
Geometry uses metres, right-handed Z-up, and row-major object matrices.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time
import traceback
import uuid


def native_module():
    root = Path(os.environ['APPDATA']) / 'Blender Foundation/Blender'
    bundled = Path(__file__).resolve().parent / 'vendor/d5_export/tools'
    paths = ([bundled] if bundled.is_dir() else []) + sorted(
        root.glob('*/scripts/addons/d5_export/tools'), reverse=True)
    for path in paths:
        if any(path.glob('d5plugin.cp%d%d-*.pyd' % sys.version_info[:2])):
            sys.path.insert(0, str(path))
            import d5plugin
            return d5plugin
    raise RuntimeError('No installed D5 module matches Python %s.%s' % sys.version_info[:2])


IDENTITY = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]


def stable_id(kind, value):
    return uuid.uuid5(uuid.NAMESPACE_URL, 'ingetrazo-d5-poc/' + kind + '/' + str(value)).hex


def transform_array(matrix):
    # Source matrix with translation in centimetres. The Blender submission
    # adapter below supplies its separate native matrix convention.
    a = [[float(v) for v in row] for row in matrix]
    if len(a) != 4 or any(len(row) != 4 for row in a):
        raise ValueError('Expected a 4x4 transform')
    if not all(math.isfinite(v) for row in a for v in row):
        raise ValueError('Transform must contain finite values')
    for i in range(3):
        a[i][3] *= 100.0
    return [a[r][c] for c in range(4) for r in range(4)]


def blender_transform_array(matrix):
    # BlenderAddNode keeps mesh positions in source axes. Its native transform
    # conversion needs M @ S (swapped columns), yielding S @ M in the D5 file.
    # The resulting world positions match the separately converted camera.
    values = transform_array(matrix)
    return values[4:8] + values[:4] + values[8:]


def camera_values(camera):
    vectors = [[float(x) for x in camera[key]] for key in ('position', 'forward', 'up')]
    if any(len(v) != 3 or not all(math.isfinite(x) for x in v) for v in vectors):
        raise ValueError('Camera requires finite three-component position/direction/up vectors')
    position, forward, up = vectors
    for vector in (forward, up):
        length = math.sqrt(sum(v*v for v in vector))
        if length < 1e-9:
            raise ValueError('Camera direction and up vectors must be nonzero')
        vector[:] = [v/length for v in vector]
    fov = float(camera['horizontal_fov'])
    width = float(camera.get('orthographic_width', 1))
    if not math.isfinite(fov) or not 0 < fov < 180 or not math.isfinite(width) or width <= 0:
        raise ValueError('Invalid camera field of view or orthographic width')
    # Same handedness/axis conversion as D5's own Blender camera helper.
    transform = [position[1]*100, position[0]*100, position[2]*100,
                 forward[1], forward[0], forward[2], up[1], up[0], up[2]]
    return transform, fov, width*100


def triangle_buffers(obj, stats=None):
    import numpy as np
    vertices = np.asarray(obj['vertices'], dtype=np.float32)
    triangles = np.asarray(obj['triangles'], dtype=np.int32)
    if vertices.ndim != 2 or vertices.shape[1] != 3 or not np.isfinite(vertices).all():
        raise ValueError('Vertices must be finite Nx3 coordinates')
    if triangles.size == 0:
        return None
    if triangles.ndim != 2 or triangles.shape[1] != 3:
        raise ValueError('Triangles must be Nx3 indices')
    if triangles.min() < 0 or triangles.max() >= len(vertices):
        raise ValueError('Triangle index outside vertex array')
    coords = vertices[triangles].reshape(-1, 3)
    normals = np.cross(coords[1::3] - coords[0::3], coords[2::3] - coords[0::3])
    lengths = np.linalg.norm(normals, axis=1)
    # Native buffers use float32. Imported slivers, repeated mesh indices or
    # rounding at large coordinates can collapse individual triangles. Mask
    # those primitives, not the entire object's valid geometry or the snapshot.
    valid = np.isfinite(lengths) & (lengths > 1e-12)
    skipped = int((~valid).sum())
    if stats is not None:
        stats['skipped_degenerate_triangles'] += skipped
    if not valid.any():
        return None
    triangles = triangles[valid]
    coords = coords.reshape(-1, 3, 3)[valid].reshape(-1, 3)
    normals = normals[valid]
    lengths = lengths[valid]
    if 'normals' in obj:
        supplied = np.asarray(obj['normals'], dtype=np.float32)
        if supplied.shape != vertices.shape or not np.isfinite(supplied).all():
            raise ValueError('Normals must be finite Nx3 values, one per vertex')
        normal_lengths = np.linalg.norm(supplied, axis=1)
        if (normal_lengths <= 1e-12).any():
            raise ValueError('Vertex normals must be nonzero')
        supplied = supplied / normal_lengths[:, None]
        normals = supplied[triangles].astype(np.float32).ravel()
    else:
        normals /= lengths[:, None]
        normals = np.repeat(normals, 3, axis=0).astype(np.float32).ravel()
    count = len(triangles)
    loops = np.arange(count * 3, dtype=np.int32)
    polygon_indices = np.arange(count, dtype=np.int32)
    material_indices = np.zeros(count, dtype=np.int32)
    if 'uvs' in obj:
        uv = np.asarray(obj['uvs'], dtype=np.float32)
        if uv.shape != (len(vertices), 2) or not np.isfinite(uv).all():
            raise ValueError('UV coordinates must be finite Nx2 values, one per vertex')
        uvs = uv[triangles].astype(np.float32).ravel()
    else:
        uvs = np.zeros(count * 6, dtype=np.float32)
    # Keep source positions and normals together. BlenderAddNode receives these
    # arrays in metres, with a scale factor of 100 and its converted node frame.
    # camera_values is a separate API requiring an explicitly converted D5 pose.
    return (coords.astype(np.float32).ravel(), normals, loops, loops.copy(),
            uvs, polygon_indices, material_indices)


def object_fingerprint(obj):
    """Hash native numeric data directly, without formatting millions of numbers."""
    import numpy as np
    arrays = {'vertices': '<f4', 'triangles': '<i4', 'normals': '<f4', 'uvs': '<f4'}
    digest = hashlib.sha256(json.dumps({k: v for k, v in obj.items() if k not in arrays},
                                    sort_keys=True, allow_nan=False).encode())
    for name, dtype in arrays.items():
        if name in obj:
            values = np.asarray(obj[name], dtype=dtype, order='C')
            digest.update(name.encode())
            digest.update(str(values.shape).encode())
            digest.update(values.tobytes())
    return digest.hexdigest()


class Bridge:
    def __init__(self, source_path, connect=False, launch=False, d5_path=None, texture_folder=None):
        self.d = native_module()
        self.source_path = str(Path(source_path).resolve())
        self.texture_folder = Path(texture_folder).resolve() if texture_folder else None
        self.connect_live = connect
        self.hashes = {}
        self.material_hashes = {}
        self.degenerate_counts = {}
        self.d.D5SetDccPluginInfo('blender')
        self.d.SetSyncMode(self.d.SyncMode.MESH_SYNC)
        installation = Path(d5_path).resolve() if d5_path else Path(os.environ['APPDATA']) / 'D5 Render'
        if d5_path and not (installation / 'd5_launcher.exe').is_file():
            raise ValueError('D5 installation folder must contain d5_launcher.exe')
        self.d.SetD5RenderPath(str(installation))
        self.session = None
        self.connection = None
        print('D5 initial status: ' + str(self.d.GetD5RenderStatus(False)), file=sys.stderr, flush=True)
        if launch:
            self._launch_link()
        if connect:
            result = self.d.D5InitMeshSyncClient('127.0.0.1', 12121, 15000, 'blender')
            self.connection = str(result)
            if result != self.d.ConnectRet.SUCCESS:
                self.close()
                raise RuntimeError('D5InitMeshSyncClient: ' + str(result))
        self._new_session()

    def _new_session(self):
        self.session = self.d.CreateSession()
        self.d.SetGenMatInstances(self.session, True)
        self.d.D5SetMaterialVersion(self.session, self.d.MaterialVersion.MAT_V2)
        self.d.D5SetSceneSettings(self.session, 1.0, self.d.Handness.RightZUp,
                                  self.d.FaceClockwise.CW)
        self.d.SetModelFilePath(self.session, self.source_path)
        if not self.connect_live:
            self.d.ExportStart(self.session)

    def _launch_link(self):
        # This must be the same process as the subsequent native connection.
        # The launcher/supervisor bounds this potentially interactive operation.
        result = self.d.StartLinkD5Render(self.source_path)
        self.connection = str(result)
        if result != self.d.ConnectRet.SUCCESS:
            raise RuntimeError('StartLinkD5Render: ' + str(result))

    def info(self):
        return {'python': sys.version, 'blender_imported': 'bpy' in sys.modules,
                'native_module': self.d.__file__, 'd5_version': self.d.D5GetRenderVersion(),
                'd5_status': str(self.d.GetD5RenderStatus(False)),
                'connection': self.connection, 'source_path': self.source_path,
                'camera_sync': True,
                'native_log_dir': self.d.D5GetLogDir()}

    def identifier(self, kind, value):
        return stable_id(kind, self.source_path + '\0' + str(value))

    def snapshot(self, scene):
        started = time.perf_counter()
        objects = scene.get('objects', [])
        # Validate the whole incoming snapshot before modifying the native session.
        if len({str(o['id']) for o in objects}) != len(objects):
            raise ValueError('Duplicate object IDs')
        stats = {'skipped_degenerate_triangles': 0}
        rebuild = not self.connect_live
        prepared = []
        next_degenerate_counts = {}
        for obj in objects:
            key = str(obj['id'])
            digest = object_fingerprint(obj)
            transform = blender_transform_array(obj.get('transform', IDENTITY))
            object_changed = self.hashes.get(key) != digest
            before = stats['skipped_degenerate_triangles']
            if object_changed or rebuild:
                buffers = triangle_buffers(obj, stats)
                next_degenerate_counts[key] = stats['skipped_degenerate_triangles'] - before
            else:
                buffers = None
                next_degenerate_counts[key] = self.degenerate_counts.get(key, 0)
                stats['skipped_degenerate_triangles'] += next_degenerate_counts[key]
            prepared.append((obj, buffers, transform, digest, object_changed))
        texture_folder = None
        if scene.get('texture_folder'):
            document = Path(scene['document_path']).resolve()
            expected = self.texture_folder or document.parent / (document.stem + '_d5_textures')
            texture_folder = Path(scene['texture_folder']).resolve()
            if document.suffix.lower() != '.skp' or not document.is_file():
                raise ValueError('Texture sync requires a saved SketchUp .skp document')
            if texture_folder != expected or not texture_folder.is_dir():
                raise ValueError('Texture folder must match the configured folder or model companion folder')
        for material in scene.get('materials', []):
            alpha = float(material.get('alpha', 1.0))
            if not math.isfinite(alpha) or not 0 <= alpha <= 1:
                raise ValueError('Material alpha must be between zero and one')
            if material.get('diffuse_map'):
                image = Path(material['diffuse_map']).resolve()
                if texture_folder is None or image.parent != texture_folder or not image.is_file():
                    raise ValueError('Diffuse texture must exist inside the model companion folder')
        # ExportStart sessions accumulate static instances rather than applying
        # live deletion commands. Rebuild offline snapshots in a fresh session.
        if rebuild:
            self.close()
            self._new_session()
        prepared_at = time.perf_counter()
        d, s = self.d, self.session
        if texture_folder is not None:
            d.SetTextureFolder(s, str(texture_folder))
        next_material_hashes = dict(self.material_hashes)
        next_hashes = dict(self.hashes)
        materials = scene.get('materials', []) + [{'id': '__default__', 'name': 'Default',
                                                   'color': '#FFFFFF'}]
        materials_changed = 0
        for mat in materials:
            key = str(mat['id'])
            digest = json.dumps([scene.get('opacity_mode', 'opaque'), mat], sort_keys=True)
            material_changed = self.material_hashes.get(key) != digest
            if not material_changed and not rebuild:
                continue
            mid = self.identifier('material', key)
            d.D5AddMaterial(s, mid)
            if key not in self.material_hashes or rebuild:
                d.D5ResetMaterial(s, mid)
            alpha = float(mat.get('alpha', 1.0)) if scene.get('opacity_mode') == 'sketchup' else 1.0
            d.D5SetMaterialType(s, mid, d.D5MaterialType.MT_OPACITY if alpha < 1.0 else d.D5MaterialType.MT_CUSTOM)
            # Vendor Blender material schema: "Opacity " is transmission amount.
            d.D5SetMaterialFloatProperty(s, mid, 'Opacity ', 1.0 - alpha)
            d.D5SetMaterialStringProperty(s, mid, 'name', mat.get('name', key))
            d.D5SetMaterialStringProperty(s, mid, 'Diffuse (Color)', mat.get('color', '#FFFFFF'))
            if mat.get('diffuse_map'):
                d.D5SetMaterialStringProperty(s, mid, 'Diffuse Map', str(Path(mat['diffuse_map']).resolve()))
            else:
                d.D5RemoveMaterialProperty(s, mid, 'Diffuse Map')
            d.D5SetMaterialFloatProperty(s, mid, 'Roughness Map (opacity)', float(mat.get('roughness', .5)))
            d.D5SetMaterialFloatProperty(s, mid, 'Metallic', float(mat.get('metallic', 0.0)))
            d.D5SetMaterialFloatProperty(s, mid, 'Specular', float(mat.get('specular', .5)))
            next_material_hashes[key] = digest
            materials_changed += int(material_changed)
        materials_at = time.perf_counter()
        seen = set()
        changed = 0
        for obj, buffers, transform, digest, object_changed in prepared:
            key = str(obj['id'])
            seen.add(key)
            if not object_changed and not rebuild:
                continue
            node = self.identifier('node', key) + '0' * 32
            d.D5DeleteNode(s, node)
            if buffers is not None:
                mid = self.identifier('material', str(obj.get('material_id', '__default__')))
                coords, normals, loops, vertex_ids, uvs, polygon_indices, material_indices = buffers
                # Use the connector's Blender submission path. The generic Max
                # path exported valid arrays but rendered this linked house dark
                # even with all materials white; the Blender path renders it normally.
                # BlenderAddNode flips V internally; preserve the host's existing
                # final D5 UV convention rather than inverting every texture.
                blender_uvs = uvs.copy()
                blender_uvs[1::2] = 1.0 - blender_uvs[1::2]
                d.BlenderAddNode(s, node, node, transform, [mid], loops, vertex_ids,
                                coords, normals, blender_uvs, polygon_indices, material_indices, 100., True)
            next_hashes[key] = digest
            changed += int(object_changed)
        removed = set(self.hashes) - seen
        for key in removed:
            d.D5DeleteNode(s, self.identifier('node', key) + '0' * 32)
            del next_hashes[key]
        result = {'changed': changed, 'removed': len(removed),
                  'materials_changed': materials_changed, 'objects': len(next_hashes),
                  'skipped_degenerate_triangles': stats['skipped_degenerate_triangles'],
                  'native_statistics': d.GetNodeStatics(s),
                  'native_instances': d.D5InstanceCount(s)}
        nodes_at = time.perf_counter()
        connected_at = nodes_at
        if self.connect_live and (changed or removed or materials_changed):
            status = d.D5ProcessedSyncConnect(s)
            connected_at = time.perf_counter()
            result['send_connection'] = str(status)
            if status != d.ConnectRet.SUCCESS:
                raise RuntimeError('D5ProcessedSyncConnect: ' + str(status))
            try:
                d.D5SendProcessed(s)
                result['send_call_completed'] = True
            finally:
                d.DisConnect(s)
        self.hashes = next_hashes
        self.material_hashes = next_material_hashes
        self.degenerate_counts = next_degenerate_counts
        finished_at = time.perf_counter()
        result['timings_ms'] = {'prepare': (prepared_at-started)*1000,
            'materials': (materials_at-prepared_at)*1000, 'nodes': (nodes_at-materials_at)*1000,
            'connect': (connected_at-nodes_at)*1000, 'send': (finished_at-connected_at)*1000}
        return result

    def send_camera(self, camera):
        transform, fov, width = camera_values(camera)
        d, s = self.d, self.session
        if camera.get('orthographic'):
            d.D5SetEntityIntProperty(s, d.ET_CAMERA, '', 'projection_mode', d.CAMERA_Orthographic)
            d.D5SetEntityFloatProperty(s, d.ET_CAMERA, '', 'orthogonal_width', width)
            d.D5SetEntityFloatArrayProperty(s, d.ET_CAMERA, '', 'transform', transform)
            d.D5SendCamera(s)
        else:
            d.D5SetEntityIntProperty(s, d.ET_CAMERA, '', 'projection_mode', d.CAMERA_PerspectiveView)
            d.SendCameraTransformFov(s, transform, fov)
        d.D5ResetEntityProperty(s, d.ET_CAMERA, '')
        return {'camera_sent': True, 'orthographic': bool(camera.get('orthographic'))}

    def export(self, path):
        path = str(Path(path).resolve())
        ok = self.d.D5SaveRawToD5a(self.session, path)
        return {'export_success': ok, 'path': path,
                'bytes': Path(path).stat().st_size if Path(path).exists() else 0}

    def close(self):
        if self.session is not None:
            if not self.connect_live:
                self.d.ExportEnd(self.session)
            self.d.DestroySession(self.session)
            self.session = None


def cube_scene(x=0.0, size=1.0, color='#DB613B'):
    return {'materials': [{'id': 'cube-material', 'name': 'IngeTrazo D5 probe', 'color': color}],
            'objects': [{'id': 'probe-cube', 'name': 'IngeTrazo D5 probe',
                         'vertices': [[a*size,b*size,c*size] for a,b,c in
                                      [(0,0,0),(1,0,0),(1,1,0),(0,1,0),
                                       (0,0,1),(1,0,1),(1,1,1),(0,1,1)]],
                         'triangles': [[0,2,1],[0,3,2],[4,5,6],[4,6,7],
                                       [0,1,5],[0,5,4],[1,2,6],[1,6,5],
                                       [2,3,7],[2,7,6],[3,0,4],[3,4,7]],
                         'transform': [[1,0,0,x],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
                         'material_id': 'cube-material'}]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stdio', action='store_true')
    parser.add_argument('--connect', action='store_true')
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--acceptance', action='store_true')
    parser.add_argument('--source', default=str(Path(__file__).with_name('ingetrazo-d5-probe.blend')))
    parser.add_argument('--output', default=str(Path(__file__).with_name('acceptance.json')))
    args = parser.parse_args()
    # Native libraries may print: keep the line protocol on a duplicated stdout,
    # and send ordinary Python diagnostics to stderr.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), 'w', encoding='utf8', buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr
    bridge = None
    record = {'pass': False, 'mode': 'live_api' if args.connect else 'native_offline',
              'visual_verified': False, 'steps': []}
    try:
        bridge = Bridge(args.source, args.connect, args.launch)
        record['info'] = bridge.info()
        if args.stdio:
            for line in sys.stdin:
                try:
                    request = json.loads(line)
                    op = request.get('op')
                    if op == 'snapshot':
                        reply = bridge.snapshot(request['scene'])
                    elif op == 'camera':
                        reply = bridge.send_camera(request['camera'])
                    elif op == 'info':
                        reply = bridge.info()
                    elif op == 'export':
                        reply = bridge.export(request['path'])
                    elif op == 'quit':
                        break
                    else:
                        raise ValueError('Unknown operation: ' + str(op))
                    print(json.dumps(dict(ok=True, op=op, **reply)), file=protocol, flush=True)
                except Exception as error:
                    print(json.dumps({'ok': False, 'error': str(error)}), file=protocol, flush=True)
            return
        print(json.dumps(record['info']), file=protocol, flush=True)
        if args.acceptance:
            stages = [('create', cube_scene()), ('unchanged', cube_scene()),
                      ('move', cube_scene(x=2)), ('geometry', cube_scene(x=2,size=1.5)),
                      ('material', cube_scene(x=2,size=1.5,color='#2B88D8')),
                      ('delete', {'objects': []}), ('restore', cube_scene())]
            for name, scene in stages:
                result = bridge.snapshot(scene)
                record['steps'].append(dict(stage=name, **result))
                print(json.dumps(record['steps'][-1]), file=protocol, flush=True)
                if args.connect:
                    time.sleep(2)
            record['export'] = bridge.export(str(Path(args.output).with_suffix('.d5a')))
            assert record['steps'][1]['changed'] == 0
            assert record['steps'][5]['removed'] == 1
            assert record['export']['export_success'] and record['export']['bytes'] > 0
            record['pass'] = True
    except Exception as error:
        record['error'] = str(error)
        print(json.dumps({'ok': False, 'error': str(error)}), file=protocol, flush=True)
        traceback.print_exc(file=sys.stderr)
    finally:
        if bridge is not None:
            bridge.close()
        Path(args.output).write_text(json.dumps(record, indent=2), encoding='utf8')
    if not record['pass'] and args.acceptance:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
