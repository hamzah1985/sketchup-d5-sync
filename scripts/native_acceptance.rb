# Development-only, temporary operation; never ships as a menu command.
require 'json'
require 'fileutils'
Sketchup.require(File.expand_path('../bogdan_d5_sync/scene', __dir__)) unless defined?(BogdanD5Sync::Scene)
model = Sketchup.active_model
original_count = model.entities.length
original_materials = model.materials.length
original_modified = model.modified?
view = model.active_view
saved_camera = view.camera
raise 'Use a normal perspective or orthographic view for this harness' if saved_camera.is_2d?
original_pose = BogdanD5Sync::Scene.camera(view)
# View#camera is a live handle; retaining it does not preserve a prior pose.
original_camera = Sketchup::Camera.new(saved_camera.eye.to_a, saved_camera.target.to_a,
  saved_camera.up.to_a, saved_camera.perspective?, 45.0)
original_camera.aspect_ratio = saved_camera.aspect_ratio
if saved_camera.perspective?
  aspect = saved_camera.aspect_ratio > 0 ? saved_camera.aspect_ratio : view.vpwidth.to_f / view.vpheight
  horizontal = original_pose['horizontal_fov']
  original_camera.fov = original_camera.fov_is_height? ?
    2.0 * Math.atan(Math.tan(horizontal * Math::PI / 360.0) / aspect) * 180.0 / Math::PI : horizontal
else
  original_camera.height = saved_camera.height
end
original_camera.image_width = saved_camera.image_width
output = File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'acceptance')
FileUtils.mkdir_p(output)
checks = []
model.start_operation('Verify D5 Sync Export', true)
begin
  group = model.entities.add_group
  group.name = 'D5 temporary acceptance'
  face = group.entities.add_face([0,0,0], [1.m,0,0], [1.m,1.m,0], [0,1.m,0])
  face.reverse! if face.normal.z < 0
  face.pushpull(1.m)
  group.transform!(Geom::Transformation.translation([2.m,3.m,0]))
  texture_path = File.expand_path('checker.png', __dir__)
  material = model.materials.add('D5 temporary texture')
  material.texture = texture_path
  textured = group.entities.grep(Sketchup::Face).find { |f| f.normal.z > 0.9 }
  textured.material = material
  folder = File.join(output, 'acceptance_d5_textures')
  FileUtils.mkdir_p(folder)
  scene = BogdanD5Sync::Scene.new(model, folder).capture
  objects = scene['objects'].select { |o| o['id'].start_with?(group.persistent_id.to_s + '/') }
  raise 'Missing cube buckets' unless objects.length == 2
  plain = objects.find { |o| o['material_id'] == '__default__' }
  raise 'White default faces missing' unless plain && plain['triangles'].length == 10
  checks << 'Unpainted cube uses default white, with 12 triangles in total'
  all_points = objects.map do |o|
    o['vertices'].map { |p| (0..2).map { |i| p[i] + o['transform'][i][3] } }
  end.flatten(1)
  mins = (0..2).map { |i| all_points.map { |p| p[i] }.min }
  maxs = (0..2).map { |i| all_points.map { |p| p[i] }.max }
  raise 'Incorrect metres or transform' unless mins.zip([2,3,0]).all? { |a,b| (a-b).abs < 1.0e-6 } && maxs.zip([3,4,1]).all? { |a,b| (a-b).abs < 1.0e-6 }
  checks << 'Nested placement and inch-to-metre conversion'
  texture_material = scene['materials'].find { |m| m['id'] == 'material-' + material.entityID.to_s }
  raise 'Embedded texture not exported' unless texture_material && File.file?(texture_material['diffuse_map'])
  checks << 'Embedded texture copied to companion directory'
  textured_bucket = objects.find { |o| o['material_id'] == texture_material['id'] }
  helper = textured.get_UVHelper(true, false)
  textured.mesh(5).points.each_with_index do |point, index|
    uvq = helper.get_front_UVQ(point)
    expected = [uvq.x / uvq.z, 1.0 - uvq.y / uvq.z]
    raise 'SketchUp UVQ vertical convention was not converted' unless
      textured_bucket['uvs'][index].zip(expected).all? { |actual, want| (actual - want).abs < 1.0e-8 }
  end
  checks << 'Front-face UVQ converts bottom-up V to the bridge texture convention'
  group.transform!(Geom::Transformation.translation([100000000.m,0,0]))
  distant = BogdanD5Sync::Scene.new(model, folder).capture['objects'].select { |o| o['id'].start_with?(group.persistent_id.to_s + '/') }
  raise 'Distant geometry was not rebased' unless distant.all? { |o| o['vertices'].flatten.all? { |value| value.abs <= 1.000001 } }
  raise 'Distant placement lost' unless distant.all? { |o| o['transform'][0][3] >= 100000002 }
  checks << 'Distant geometry retains small local coordinates and world placement'
  group.transform!(Geom::Transformation.translation([-100000000.m,0,0]))
  group.transform!(Geom::Transformation.scaling(ORIGIN, -2, 3, 0.5))
  mirrored = BogdanD5Sync::Scene.new(model, folder).capture['objects'].select { |o| o['id'].start_with?(group.persistent_id.to_s + '/') }
  mirrored.each do |object|
    object['triangles'].each do |triangle|
      points = triangle.map { |i| Geom::Point3d.new(object['vertices'][i]) }
      cross = (points[1] - points[0]).cross(points[2] - points[0])
      normal = Geom::Vector3d.new(object['normals'][triangle[0]])
      raise 'Mirrored normal disagrees with winding' unless cross.dot(normal) > 0
    end
  end
  checks << 'Mirrored nonuniform scaling retains outward normals and winding'
  group.hidden = true
  hidden = BogdanD5Sync::Scene.new(model, folder).capture
  raise 'Hidden parent leaked' if hidden['objects'].any? { |o| o['id'].start_with?(group.persistent_id.to_s + '/') }
  checks << 'Hidden containers excluded'
  camera = Sketchup::Camera.new([2.m,3.m,4.m], [2.m,4.m,4.m], [0,0,1])
  camera.fov = 60
  model.active_view.camera = camera
  captured = BogdanD5Sync::Scene.camera(model.active_view)
  raise 'Camera eye or direction changed' unless captured['position'].zip([2,3,4]).all? { |a,b| (a-b).abs < 1e-6 } && captured['forward'] == [0.0,1.0,0.0]
  raise 'Horizontal FOV invalid' unless captured['horizontal_fov'] > 0 && captured['horizontal_fov'] < 179
  checks << 'Camera position, direction and horizontal field of view'
  camera.perspective = false
  camera.height = 2.m
  model.active_view.camera = camera
  ortho = BogdanD5Sync::Scene.camera(model.active_view)
  raise 'Orthographic width incorrect' unless ortho['orthographic'] && ortho['orthographic_width'] > 0
  checks << 'Orthographic camera dispatch'
  File.open(File.join(output, 'scene.json'), 'wb') { |f| f.write(JSON.generate(scene)) }
ensure
  model.abort_operation
  model.active_view.camera = original_camera
end
raise 'Model changed during read-only acceptance' unless model.entities.length == original_count && model.materials.length == original_materials && model.modified? == original_modified
restored_pose = BogdanD5Sync::Scene.camera(model.active_view)
raise 'Camera pose changed during acceptance' unless original_pose.all? do |key, value|
  actual = restored_pose[key]
  if value.is_a?(Array)
    value.zip(actual).all? { |a,b| (a-b).abs < 1e-8 }
  elsif value.is_a?(Numeric)
    (value-actual).abs < 1e-8
  else
    value == actual
  end
end
checks << 'Original camera position, orientation, projection and field of view restored'
record = {:pass => true, :checks => checks, :model_unchanged => true, :sketchup => Sketchup.version}
File.open(File.join(output, 'native-acceptance.json'), 'wb') { |f| f.write(JSON.pretty_generate(record)) }
JSON.generate(record)
