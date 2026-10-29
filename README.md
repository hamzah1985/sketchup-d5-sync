# D5 Sync for SketchUp — experimental

By Bogdan Demchenko. Initial version 0.1.0, build 1. Windows only; intended
for local testing in SketchUp 2026/2027. No Warehouse package is built.

This is separate from the official D5 SketchUp connector and the IngeTrazo
adapter. It reuses our own Python bridge to the separately installed D5
LiveSync for Blender native module. Blender stays closed during sync.
D5 Render, a matching Python runtime and NumPy must already be installed.
No vendor binaries or installers are redistributed.

## Install from this repository

This is a source distribution, not a self-contained installer or an official D5
extension. Current local testing covers Windows, SketchUp 2026/2027 and D5
3.1.1.0755. Other versions are not certified.

1. Install SketchUp and D5 Render, then install D5 LiveSync for Blender from
   D5's official distribution. The connector needs that separately installed
   native module and a matching Python runtime with NumPy. Installing a matching
   Blender version supplies the runtime; Blender does not run during sync.
2. Download this repository using GitHub's **Code > Download ZIP** and extract it.
3. Close SketchUp. Copy `bogdan_d5_sync.rb` and the entire `bogdan_d5_sync/`
   folder into `%APPDATA%/SketchUp/SketchUp 2027/SketchUp/Plugins/`, or the
   equivalent 2026 directory. Keep the loader and support folder side by side.
4. Start SketchUp and show **D5 Sync — Experimental** from its toolbar menu.
   Save a model, open a D5 project and click Connect.

The repository ZIP itself is not an RBZ. No RBZ release is published yet.
For installation or troubleshooting help, an assistant such as Codex can read
this README, inspect locally installed dependencies and help configure them.
Review any proposed local changes before applying them.

Use a copy of an important model and a separate D5 project for initial testing.
Material updates, camera sync and large models remain experimental; the live
test measurements below do not guarantee performance on another machine.
See [CONTRIBUTING.md](CONTRIBUTING.md) to report a bug or submit a pull request.

## Use

Restart SketchUp after deployment. The **D5 Sync — Experimental** toolbar has
four compact SVG buttons: D5 Connect, Sync Now, Disconnect and Settings. Restore it through
Extensions > D5 Sync — Experimental > Show Toolbar. Connection Status shows
the worker's last response and diagnostics location.

Save the model when connecting for the first time. Connect creates
`<model-name>_d5_textures` beside its `.skp` file. Open a new blank D5 project
if prompted. Completed modeling transactions trigger a debounced geometry
update; camera changes are sampled at up to 60 Hz. Sync Now resends scene/camera.
Changing the model path stops sync; reconnect after Save As. Disconnect leaves
D5 open. Avoid running the official connector on the same model concurrently.

Automatic capture waits 750 ms after a committed edit. With scoped editing enabled,
changes inside an open group/component recapture that definition's placements
and refresh material records, retaining cached geometry elsewhere. This includes
all instances of a shared component and material changes outside its edit context.
The initial connection or Sync Now establishes a full-scene cache. Without that
cache, exit the group or press Sync Now for the first capture. Double-clicking
into a component and aborting an uncommitted edit
do not themselves request a full export. Camera following remains active.
Timer callbacks are guarded against reentrant capture. This reduces interruptions
while editing; a full-model capture after a large edit can still pause SketchUp.
Open modeling transactions also defer capture until commit or abort. Run
`ruby test/controller_editing_test.rb` for context entry, queued edits, explicit
sync, transaction, progress announcement and timer-reentry regressions (six checks, 18 assertions).

New connections use the real saved `.skp` pathname, which D5 displays in its
model list. No SketchUp-to-Blender file conversion occurs: numeric mesh buffers
go directly to the installed D5 native module. The underlying mesh/client API
still comes from LiveSync for Blender; this is not the official SketchUp backend.
For an existing D5 project linked through the old `.blend` identity, use
Extensions > D5 Sync — Experimental > **Connect Using Legacy Blender Identity**.
That keeps its original source path and stable IDs. Switching an existing link
to `.skp` can create a separate D5 model; automatic migration of D5 material
overrides between those identities is not implemented. Preserve the old project
and test the new identity in a fresh project first.

The exporter reads the full model in world coordinates, including component
placements, visibility, inherited colors, front-side paint and smooth normals.
It does not explode components, paint faces, add attributes or change geometry.
Each exported mesh is rebased to a nearby local origin with its placement in
a separate transform, preserving small triangles far from the model origin.
The worker omits triangles that collapse at native float32 precision, retaining
the rest of the scene. Connection Status reports the skipped triangle count.
Malformed indices and non-finite source data still produce an error.
Unpainted faces become white. Mirrored winding and inverse-transpose normals
retain nonuniform scale. Explicit front texture UVQ is sampled and embedded
images export to content-named companion PNGs. SketchUp's bottom-up UVQ V is
converted to the bridge's image convention after division by Q, for both direct
face textures and inherited projections. Inherited texture mapping is a
simple local projection and may differ from SketchUp.

## Runtime and diagnostics

`Transport.python` detects installed Blender runtimes matching the native module
ABI. Set `SKETCHUP_D5_PYTHON` before starting SketchUp to use another compatible
Python executable with NumPy. The module is discovered in the standard per-user
D5 Blender add-on location. D5 is expected under `%APPDATA%/D5 Render`.

The worker launches hidden, connects over an authenticated, random loopback
port, and accepts bounded JSON control operations and `le32-v1` binary mesh
frames (little-endian float32 coordinates/normals/UVs and int32 triangle indices,
at most 512 MiB). Host API reads and numeric packing stay on the GUI thread.
Packing uses an explicit state machine, returning between blocks of at most 2,048 rows
with a 3 ms per-poll budget. It creates neither a Fiber nor an external Enumerator;
all allocations remain on the calling GUI stack. No Ruby background thread is created by the sender;
the launcher is reaped with a nonblocking main-thread wait. Native D5 processing
still runs in the separate Python process. Bounded nonblocking socket I/O runs on the GUI timer,
including immediate small camera writes, so a busy host does not postpone them
for a Ruby background thread's scheduling timeslice. Partial writes and reads
resume at the next timer visit. The controller no longer formats or
hashes full-scene JSON on the GUI thread. TCP_NODELAY avoids small-message
coalescing, and native buffer construction is skipped for unchanged meshes.
The worker still validates changed meshes before touching its native session.
After the initial full snapshot, the sender compares numeric mesh records with
the last sent scene and transfers only changed meshes plus explicit removed IDs.
The worker reconstructs the full scene from its per-connection cache before native
validation. All material records remain current; a color-only repaint transfers
no unchanged mesh buffers. Reassigning faces can change their material buckets,
so those affected meshes still transfer and D5 still processes their geometry.
The cache is discarded on disconnect, and a new connection starts with a full
snapshot. This reduces packing/transfer work, not D5's own processing time.
The authenticated transport integration checks material-only delta updates,
retained native geometry, deletion and reappearance before native export.
Live timing on the 254,185-triangle private house copy measured initial full
packing at 7,099 ms for 19,078,823 bytes. Two material-only updates transferred
18,274 bytes, packed in 51–69 ms and acknowledged in 1,144–1,207 ms, excluding
SketchUp capture/debounce and D5 viewport completion. Native worker processing
was about 282–336 ms. Three live acknowledgements plus the final restoration
completed without crashing. These are local measurements, not a guaranteed
latency for reassignment that changes mesh buckets. Each worker now records
`snapshot-metrics.jsonl` with preparation, material, node, connect and send timings
and changed/received mesh counts; it does not record model geometry or textures.
Progress status is best-effort telemetry. Windows can briefly prevent atomic
replacement while the host reads the old status file. Such write/read failures
are logged, retain the last readable stage and do not fail the snapshot or
disconnect sync. The next status update attempts publication again. Regression:
`test/test_progress_status.py` forces locked-target and unwritable-temp failures
and verifies recovery without losing the last valid status.

Only one request is in flight,
and newer camera positions replace intermediate unsent positions. Requests
time out after 60 seconds. Disconnect closes the socket and terminates only
this run's worker if it has not exited. Logs and generated per-model empty
legacy connection identities live under `%LOCALAPPDATA%/BogdanD5Sync`, outside
Plugins. Connection Status includes the last capture, packing, transport and
native-worker timings. Geometry capture still reads the full model on the GUI
thread; large edits can interrupt camera following during capture and native
scene updates. A 60 Hz sampling target does not guarantee 60 rendered updates.

## Development verification

`scripts/native_acceptance.rb` runs through the existing SketchUp Ruby runner.
It tests a temporary cube, transforms, mirroring, white default faces, texture
extraction, distant-coordinate precision, visibility and camera conversion in an abortable operation and
restores the camera from an independent value copy (the view's camera is a live
handle). It checks the restored pose/projection/FOV, and rejects changes to entity/material counts or the model's
modified state. Results live in the user-profile acceptance directory.

Python worker checks: `python -m unittest discover -s test -p 'test_*.py' -v`.
These need the separately installed native module for offline export checks.
Binary interoperability also uses `ruby` on PATH. Run
`ruby test/transport_nonblocking_test.rb` for partial-write/backpressure and
fragmented-response coverage. `ruby test/transport_integration.rb` tests the
actual hidden authenticated worker, `.skp` source identity, binary snapshot
and native offline export; it needs `Transport.python` or
`SKETCHUP_D5_PYTHON` pointing to the matching installed runtime.
Ruby syntax must remain compatible with Ruby 2.2 even though deployed only to
2026/2027. Source is `bogdan_d5_sync.rb` plus `bogdan_d5_sync/`; deployed copies
are not implementation sources. Do not modify Kitchen Crafter or the official
`d5_converter` extension while developing this plugin.

Known limits: front-side materials only, transparency/glass, image entities,
face-me billboards, cutting-component holes, section cuts, two-point camera
shift and exact inherited/projected texture appearance. Live orthographic and
large-model behavior need visual acceptance. The private D5 API may change.
Native/offline checks do not certify every live rendering case.

The 29 October material-crash mitigation removes the old allocation-heavy Ruby
packing thread and guards scene capture against off-thread API calls. The crash
dump recorded a native null write in SketchUp; it did not prove the triggering
extension or call. The corrected sender completed 30 repaint/capture/native-worker
cycles on an 82,258-triangle disposable SketchUp 2027 fixture, alternating full
and scoped capture with forced garbage collection. This is not a guarantee for
the user's house or an exact reproduction of interactive Paint-tool gestures.
The prior sender also passed the same 30-cycle scripted baseline, so the exact
cause remains unproven. The corrected sender additionally completed five full
capture/native-offline-worker repaint cycles on a private saved-house copy with
254,185 triangles, real textures, PaintTool selected and forced GC. The original
document was untouched. This checks the local sender/export path, not live D5
viewport completion. `scripts/house_repaint_regression.rb` consumes a local-only
`house_regression_local.json` containing a disposable copy path; never commit
that configuration or any private test document.
`scripts/repaint_stress.rb` requires a fresh disposable process and saves only
its generated fixture/profile report. Never run it in a user's working model.
`ruby test/packet_incremental_test.rb` checks cooperative yielding, unchanged
thread count and wire dimensions. Capture start/end and snapshot acknowledgements
are recorded in each run's `host-events.jsonl` to narrow any further native crash.
The subsequent 12:46 crash occurred after capture finished and before the second
snapshot acknowledgement. Its WER dump recorded the same native null write and
an exception stack in a Ruby Fiber region. This is evidence for removing the
remaining stack-switching encoder, not proof of a particular native caller.
The encoder now advances with ordinary indexed state and no alternate Ruby stack.
The earlier thread-only mitigation did not resolve the user's interactive crash.
The indexed encoder then completed ten live D5 snapshot acknowledgements on the
254,185-triangle private house copy, with PaintTool selected, plain/textured
material changes and forced GC during packing, followed by an acknowledged
restoration of the original material colors. The report recorded one caller
Fiber throughout. This provides live regression evidence; it does not unwind
the native crash stack or establish every interactive failure's root cause.
`scripts/live_repaint_regression.rb` requires a fresh disposable process and
explicit `D5_REGRESSION_COPY` / `D5_REGRESSION_IDENTITY` environment paths. It
never saves the test document and restores test colors in the linked D5 model.

## Settings and texture storage

Connect opens a small nonblocking progress window, also available through
Extensions > D5 Sync — Experimental > Show Sync Progress. It shows named stages
for startup/project waiting, geometry and texture capture, packing/transfer and
native processing. A spinner and elapsed time indicate work; no invented
percentage is shown. The final acknowledgement says the model was sent because
D5 does not report when viewport rendering finishes. The popup auto-closes 1.5 seconds after a successful send; newer work cancels
that close timer. Errors remain visible. Closing the popup leaves sync running; Disconnect stops the owned worker. The status bar mirrors stages.

The gear opens a utility popup with native folder pickers. Settings persist in
`%LOCALAPPDATA%/BogdanD5Sync/settings.json`, never Plugins. Blank texture root
uses the existing companion directory beside each saved SKP. A chosen shared
folder collects exported embedded textures from all models using content-based
names; existing folders/files are retained. The next capture extracts any
missing images. The worker accepts that exact configured folder and requires
each diffuse image to exist directly inside it. Paths supplied in scene payloads
alone cannot authorize another folder. No texture cleanup or relocation is done.

The D5 installation folder may be automatic or selected explicitly; a custom
folder must contain `d5_launcher.exe`. Camera following and automatic updates
can be toggled, camera sampling is bounded to 15–60 Hz, and edit delay to
250–5000 ms. Scoped updates inside group/component editing are optional. Saving disconnects the current
worker; reconnect explicitly to apply all settings together. Sync Now remains
available when automatic updates are off. Actual throughput depends on the model.

Opaque mode preserves previous behavior. Experimental SketchUp opacity sends
material alpha using the vendor's MT_OPACITY template and `Opacity ` transmission
property (1 minus alpha); zero transparency restores MT_CUSTOM. Native exported
XML is verified; final live shading, texture alpha cutouts and physically accurate
glass remain unverified. This does not alter source SketchUp materials. Exposure,
lighting and D5 effects are not controlled by these preferences.

Settings checks: `ruby test/settings_test.rb` plus
`python -m unittest discover -s test -p 'test_*.py'`. The worker checks include
authorized shared-folder export, rejected unconfigured folders, native opacity
serialization, invalid alpha and invalid D5 installation paths.

Local verification on 28 October 2026: all four production Ruby files parsed
with the Ruby 2.2 parser, seven native SketchUp 2027 acceptance checks passed
with the model unchanged, eleven native Python bridge checks passed, and the
hidden authenticated transport completed a real native-module handshake.
A disposable saved cube reached D5's model list and the controller received
successful perspective-camera acknowledgements. Visual live camera movement
and final viewport appearance are still for user acceptance; they are not
claimed verified by these acknowledgements.

The same-day degenerate-triangle fix passed 16 native worker checks and eight
SketchUp acceptance checks, including distant-coordinate rebasing. Regression
coverage includes mixed valid/collapsed triangles with aligned UVs and smooth
normals, float32 collapse, entirely collapsed objects disappearing/reappearing,
native export, and continued rejection of non-finite source coordinates.

Geometry now uses the connector's BlenderAddNode path. Source positions/normals
stay local; its input matrix swaps the first two columns after scaling translation
to centimetres. Native output is compared in world space with the explicitly
converted camera. The internal V flip is compensated to preserve texture mapping.
This replaces the generic Max submission path, which displayed the IngeTrazo
house dark even with all-white materials while the Blender path rendered it
normally under the same camera and lighting. The subsequent SketchUp material
acceptance is recorded below. Test updates in a new blank D5 project.

The native scene uses CW. All twenty native-worker checks pass, including actual
world-space pose/normal checks for reflected nonuniform components, asymmetric
UV orientation, and the vendor-reference winding check. An intermediate CCW
change relied on an incorrect handedness-only assertion and is withdrawn.
Image existence and native export success alone cannot certify live shading.

Material acceptance on 28 October 2026 used a separately launched SketchUp
2026 (26.2.243), the installed connector, and a fresh D5 3.1.1.0755 project.
An eight-cube fixture (96 triangles) covered default white, face paint,
container paint, nearest-parent paint with a face override, direct textures,
mirrored and nonuniformly scaled textured geometry, and inherited textures.
The asymmetric four-color atlas exposed a vertical UV inversion; correcting V
in `scene.rb` made the visible face/top patterns match SketchUp. Live repainting,
undo and a second camera position were visually verified in D5. Reopening the
saved fixture with both its original atlas and exported cache temporarily absent
recovered the embedded image byte-for-byte into the companion directory.

The updated native SketchUp acceptance has nine passing checks, including UVQ
orientation, and confirms capture leaves the model unchanged. All twenty native
Python worker checks pass with the matching Python 3.13 runtime. The UV fix is
deployed to both 2026 and 2027; this live material review was performed in 2026.
Glass/transparency and exact arbitrary inherited/projected mapping remain limits.

To reproduce the visual fixture, first run
`python scripts/generate_material_atlas.py`, then load
`scripts/live_material_acceptance.rb` through SketchUp's Ruby runner or console
in a new, unmodified, unsaved disposable model. It saves only its generated test
model under `%LOCALAPPDATA%/BogdanD5Sync/material-acceptance-20261028` and records
the scene/materials and controller status there. Connect with the experimental
toolbar, compare the asymmetric atlas, then use
`D5MaterialAcceptance.change_materials`, `.restore_materials` and `.move_camera`.
The script rejects a saved or modified model before building its fixture.

Our code, original icons and generated empty scene are GPL-3.0-or-later; see
`bogdan_d5_sync/LICENSE`. This project is unofficial and is not endorsed by D5.
Publishing a combined native binary bundle requires separate licensing review.

On 29 October 2026, live D5 3.1.1.0755 accepted a saved `.skp` identity with
the same Blender mesh path. A fresh 96-triangle material fixture displayed
one `.skp` model with default white, colors and asymmetric textures intact.
All 24 native/packet checks, the nonblocking transport test (eight assertions),
the authenticated worker integration and ten SketchUp native checks passed
(the latter in SketchUp 2027, including camera restoration).
The live controller test in a disposable SketchUp 2026 session preserved its
model and increased camera acknowledgements from 37 to 160 over a four-second
camera sweep after replacing blocking background-thread socket I/O. The final
camera round trip was 15.6 ms; this is a local fixture measurement, not a large
project or receiver-frame-rate guarantee. Both 2026 and 2027 received the plain
source update; that live sweep was performed in 2026.

A CPU-only 154,230-triangle serialization benchmark encoded the binary frame in
192 ms (7.3 MB), compared with 845 ms per full JSON pass (24.6 MB); the former
controller performed two JSON passes. A separate local native-worker benchmark
reduced first-snapshot processing from 1,769 to 1,110 ms and unchanged-snapshot
processing from 794 to 146 ms. These isolate serialization/cache work and do not
measure total interactive latency, full-model capture or D5 rendering time.
`scripts/context_acceptance.rb` is a separate fresh-session native fixture for
scoped repainting, shared instances and global material changes; it compares
the result against a full native SketchUp capture. It creates disposable geometry
and must never run on a user's working model.
