# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded binary mesh frames on the existing authenticated local connection."""
import json

FIELDS = {'vertices': (3, '<f4'), 'triangles': (3, '<i4'),
          'normals': (3, '<f4'), 'uvs': (2, '<f4')}
MAX_PAYLOAD = 512 * 1024 * 1024


def read_request(stream):
    line = stream.readline(16 * 1024 * 1024)
    if not line:
        return None
    if not line.endswith(b'\n'):
        raise ValueError('Request header exceeds limit or is truncated')
    request = json.loads(line)
    encoding = request.get('mesh_encoding')
    if encoding is None:
        return request
    if encoding != 'le32-v1' or request.get('op') != 'snapshot':
        raise ValueError('Unknown binary mesh encoding')
    declared = request.get('payload_bytes')
    if type(declared) is not int or not 0 <= declared <= MAX_PAYLOAD:
        raise ValueError('Invalid binary payload size')
    descriptors = []
    total = 0
    for obj in request['scene']['objects']:
        for required in ('vertices', 'triangles'):
            if required not in obj:
                raise ValueError('Missing mesh array: ' + required)
        for name, (columns, dtype) in FIELDS.items():
            if name not in obj:
                continue
            descriptor = obj[name]
            rows = descriptor.get('rows')
            size = descriptor.get('bytes')
            if type(rows) is not int or rows < 0 or type(size) is not int or size != rows * columns * 4:
                raise ValueError('Invalid binary mesh dimensions')
            total += size
            if total > MAX_PAYLOAD:
                raise ValueError('Binary mesh exceeds limit')
            descriptors.append((obj, name, rows, columns, dtype, size))
    if total != declared:
        raise ValueError('Binary payload length mismatch')
    import numpy as np
    for obj, name, rows, columns, dtype, size in descriptors:
        data = stream.read(size)
        if len(data) != size:
            raise ValueError('Truncated binary mesh')
        obj[name] = np.frombuffer(data, dtype=dtype).reshape(rows, columns)
    return request
