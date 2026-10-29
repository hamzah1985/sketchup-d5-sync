require 'json'
model = Sketchup.active_model
raise 'Live test requires the untouched, empty disposable model.' unless model.path.empty? && !model.modified? && model.entities.length == 0
model.start_operation('Create D5 Sync Test Cube', true)
begin
  cube = model.entities.add_group
  cube.name = 'D5 Sync Test Cube'
  face = cube.entities.add_face([0,0,0], [1.m,0,0], [1.m,1.m,0], [0,1.m,0])
  face.reverse! if face.normal.z < 0
  face.pushpull(1.m)
  model.commit_operation
rescue StandardError
  model.abort_operation
  raise
end
camera = Sketchup::Camera.new([3.m,-4.m,3.m], [0.5.m,0.5.m,0.5.m], [0,0,1])
camera.fov = 60
model.active_view.camera = camera
filename = 'D5-Sync-Test-' + Time.now.strftime('%Y%m%d-%H%M%S') + '.skp'
path = File.join(ENV['USERPROFILE'], 'Downloads', filename)
raise 'Could not save the new disposable test model.' unless model.save(path)
BogdanD5Sync.controller.connect
File.write(File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'acceptance', 'live-model.json'), JSON.generate({'path' => model.path, 'id' => cube.persistent_id}))
