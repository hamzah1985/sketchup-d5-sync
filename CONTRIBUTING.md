# Contributing

Issues and pull requests are welcome. Describe the source-model action, expected
result, actual result, SketchUp/D5 versions and whether the issue occurs on a
small disposable model. For performance issues include the connector's timing
summary and changed mesh counts when available.

Do not upload private models, raw crash dumps, worker authentication files,
credentials, or third-party native modules. Review and redact diagnostic paths
before posting them. Use generated geometry to reproduce a problem where possible.

Keep Ruby source parseable on Ruby 2.2. SketchUp API reads must stay on the GUI
thread and its normal execution stack; do not use background Ruby threads or
Fibers for export/packing. Export must not change source geometry or materials.
Keep numeric packet compatibility and validate data before native submission.
Progress telemetry failures must not break model sync.

Run the Ruby tests individually with `ruby test/<name>_test.rb`. Run Python tests
with a matching Python/NumPy/native-module installation:

```powershell
python -m unittest discover -s test -p 'test_*.py' -v
ruby test/transport_integration.rb
```

Native dependencies are not bundled. `SKETCHUP_D5_PYTHON` can select the matching
Python executable. The native integration harness runs offline, not against the
user's open D5 project. Native SketchUp acceptance scripts must run in a fresh
disposable session. Read each script before running it; live scripts can send
data into a D5 project, and must never run on an important working model.

Retain the GPL-3.0-or-later notices. Do not add vendor binaries, installers,
machine-specific configuration or generated private diagnostics to a pull request.
