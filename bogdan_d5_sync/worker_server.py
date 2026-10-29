# SPDX-License-Identifier: GPL-3.0-or-later
"""One authenticated loopback connection to the owned D5 worker, no remote eval."""
import hmac
import json
import os
from pathlib import Path
import socket
import sys
import traceback
import time

from d5_bridge import Bridge
from packet import read_request


def write_progress(config_path, stage):
    """Best-effort UI telemetry; a Windows reader can briefly block replace."""
    try:
        temporary = config_path.with_name('worker.status.tmp')
        temporary.write_text(json.dumps({'stage': stage}), encoding='utf8')
        temporary.replace(config_path.with_name('worker.status.json'))
        return True
    except OSError as error:
        print('D5 progress update deferred: ' + str(error), file=sys.stderr)
        return False


def serve(configuration):
    config_path = Path(configuration).resolve()
    config = json.loads(config_path.read_text(encoding='utf8'))
    bridge = None
    def progress(stage):
        return write_progress(config_path, stage)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(60)
        ready = {'port': listener.getsockname()[1], 'pid': os.getpid(), 'token': config['token']}
        temporary = config_path.with_suffix('.ready.tmp')
        temporary.write_text(json.dumps(ready), encoding='utf8')
        temporary.replace(config_path.with_suffix('.ready.json'))
        try:
            connection, _ = listener.accept()
            with connection:
                connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                connection.settimeout(10)
                stream = connection.makefile('rwb')
                auth = json.loads(stream.readline(4096))
                if not hmac.compare_digest(str(auth.get('token', '')), config['token']):
                    raise ValueError('Worker authentication failed')
                # An idle model is normal. Ruby bounds individual requests and
                # closes its owned socket on disconnect or host shutdown.
                connection.settimeout(None)
                progress('Starting D5; waiting for a project to become ready')
                bridge = Bridge(config['source'], connect=config.get('connect', True),
                                launch=config.get('connect', True), d5_path=config.get('d5_path'),
                                texture_folder=config.get('texture_folder'))
                cached_objects = None
                while True:
                    request = read_request(stream)
                    if request is None:
                        break
                    op = request.get('op')
                    if op == 'quit':
                        break
                    try:
                        started = time.perf_counter()
                        if op == 'info':
                            response = bridge.info()
                        elif op == 'snapshot':
                            progress('Processing geometry and materials in D5; please wait')
                            scene = request['scene']
                            incoming = scene.get('objects', [])
                            if len({obj['id'] for obj in incoming}) != len(incoming):
                                raise ValueError('Duplicate object IDs')
                            if scene.get('mesh_delta'):
                                if cached_objects is None:
                                    raise ValueError('Mesh delta requires a full initial snapshot')
                                next_objects = dict(cached_objects)
                                for key in scene.get('removed_objects', []):
                                    next_objects.pop(key, None)
                                for obj in incoming:
                                    next_objects[obj['id']] = obj
                                scene = dict(scene, objects=list(next_objects.values()))
                            else:
                                next_objects = {obj['id']: obj for obj in incoming}
                            response = bridge.snapshot(scene)
                            cached_objects = next_objects
                            try:
                                with config_path.with_name('snapshot-metrics.jsonl').open('a', encoding='utf8') as metrics:
                                    metrics.write(json.dumps(dict(response, time=time.time(),
                                        received_meshes=len(incoming), mesh_delta=bool(scene.get('mesh_delta')))) + '\n')
                            except OSError as error:
                                print('D5 metrics write failed: ' + str(error), file=sys.stderr)
                            progress('Model sent to D5; rendering may take a moment')
                        elif op == 'camera':
                            response = bridge.send_camera(request['camera'])
                        elif op == 'export' and not config.get('connect', True):
                            response = bridge.export(request['path'])
                        else:
                            raise ValueError('Unknown worker operation: ' + str(op))
                        reply = dict(response, ok=True, op=op)
                        reply['worker_ms'] = (time.perf_counter() - started) * 1000.0
                    except Exception as error:
                        traceback.print_exc()
                        reply = {'ok': False, 'op': op, 'error': str(error)}
                    stream.write((json.dumps(reply) + '\n').encode('utf8'))
                    stream.flush()
        finally:
            if bridge is not None:
                bridge.close()


if __name__ == '__main__':
    serve(sys.argv[1])
