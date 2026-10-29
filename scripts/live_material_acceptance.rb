# Development-only fixture. Run in a separately launched, new disposable model.
require 'json'
require 'fileutils'
require 'digest'

module D5MaterialAcceptance
  ROOT = File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'material-acceptance-20261028') unless const_defined?(:ROOT)

  def self.record(name, value)
    FileUtils.mkdir_p(ROOT)
    File.open(File.join(ROOT, name + '.json'), 'wb') { |f| f.write(JSON.pretty_generate(value)) }
    value
  end

  def self.cube(entities, name, x, y, material = nil)
    group = entities.add_group
    group.name = name
    face = group.entities.add_face([0,0,0], [1.5.m,0,0], [1.5.m,1.5.m,0], [0,1.5.m,0])
    face.reverse! if face.normal.z < 0
    face.pushpull(1.5.m)
    group.transform!(Geom::Transformation.translation([x.m,y.m,0]))
    group.material = material if material
    group
  end

  def self.paint_faces(group, material)
    group.entities.grep(Sketchup::Face).each { |face| face.material = material }
  end

  def self.texture_faces(group, material)
    group.entities.grep(Sketchup::Face).each do |face|
      face.material = material
      vertices = face.vertices.map { |v| v.position }
      mapping = vertices.zip([[0,0,0],[1,0,0],[1,1,0],[0,1,0]]).flatten(1)
      face.position_material(material, mapping, true)
    end
  end

  def self.build
    model = Sketchup.active_model
    raise 'Use a new, unmodified, unsaved disposable model.' unless model.path.empty? && !model.modified?
    FileUtils.mkdir_p(ROOT)
    atlas = File.join(__dir__, 'material_atlas.png')
    raise 'Generate scripts/material_atlas.png first.' unless File.file?(atlas)
    model.start_operation('Build disposable D5 material fixture', true)
    begin
      model.entities.clear!
      @red = model.materials.add('D5 acceptance red')
      @red.color = Sketchup::Color.new(225,35,25)
      @green = model.materials.add('D5 acceptance green')
      @green.color = Sketchup::Color.new(30,185,65)
      @blue = model.materials.add('D5 acceptance blue')
      @blue.color = Sketchup::Color.new(35,70,225)
      @atlas = model.materials.add('D5 acceptance asymmetric atlas')
      @atlas.texture = [atlas, 1.5.m, 1.5.m]
      @white = cube(model.entities, '01 default white', 0, 0)
      @painted = cube(model.entities, '02 explicit red faces', 2.4, 0)
      paint_faces(@painted, @red)
      @inherited = cube(model.entities, '03 inherited green container', 4.8, 0, @green)
      @textured = cube(model.entities, '04 explicit textured faces', 7.2, 0)
      texture_faces(@textured, @atlas)
      @nested_parent = model.entities.add_group
      @nested_parent.name = '05 nested inherited and override'
      @nested_parent.material = @red
      nested = @nested_parent.entities.add_group
      nested.material = @blue
      @nested_leaf = cube(nested.entities, 'nearest parent blue with green top override', 0, 3)
      @nested_leaf.entities.grep(Sketchup::Face).find { |f| f.normal.z > 0.9 }.material = @green
      @mirrored = cube(model.entities, '06 mirrored texture', 0, 0)
      texture_faces(@mirrored, @atlas)
      @mirrored.transformation = Geom::Transformation.translation([3.9.m,3.m,0]) * Geom::Transformation.scaling(-1,1,1)
      @scaled = cube(model.entities, '07 nonuniformly scaled texture', 0, 0)
      texture_faces(@scaled, @atlas)
      @scaled.transformation = Geom::Transformation.translation([4.8.m,3.m,0]) * Geom::Transformation.scaling(1.2,0.75,1.25)
      @inherited_texture = cube(model.entities, '08 inherited texture', 7.2, 3, @atlas)
      model.rendering_options['RenderMode'] = 4
      model.active_view.camera = Sketchup::Camera.new([12.m,-16.m,14.m], [4.5.m,2.2.m,0.5.m], [0,0,1])
      model.active_view.camera.fov = 48
      model.commit_operation
    rescue StandardError
      model.abort_operation
      raise
    end
    path = File.join(ROOT, 'D5-material-fixture.skp')
    raise 'Could not save disposable fixture.' unless model.save(path)
    @model = model
    capture('baseline')
    @timer = UI.start_timer(1.0, true) { record('controller', BogdanD5Sync.controller.diagnostics) }
    puts JSON.generate({'fixture'=>path,'ready'=>true,'sketchup'=>Sketchup.version})
  end

  def self.capture(name)
    model = Sketchup.active_model
    raise 'The test model is no longer active.' unless model == @model
    before = [model.entities.length, model.materials.length, model.modified?]
    folder = BogdanD5Sync::Scene.companion(model.path)
    FileUtils.mkdir_p(folder)
    scene = BogdanD5Sync::Scene.new(model, folder).capture
    after = [model.entities.length, model.materials.length, model.modified?]
    raise 'Read-only capture changed the model.' unless before == after
    record(name + '-scene', scene)
    record(name + '-camera', BogdanD5Sync::Scene.camera(model.active_view))
    record(name + '-summary', {'pass'=>true,'model_unchanged'=>true,
           'objects'=>scene['objects'].length,'materials'=>scene['materials'],
           'triangles'=>scene['objects'].map { |o| o['triangles'].length }.inject(0,:+),
           'texture_files'=>Dir.glob(File.join(folder,'*.png')),
           'sketchup'=>Sketchup.version})
  end

  def self.change_materials
    @model.start_operation('D5 live material change acceptance', true)
    @red.color = Sketchup::Color.new(35,70,225)
    @inherited.material = @red
    @model.commit_operation
    capture('changed')
  end

  def self.restore_materials
    Sketchup.undo
    capture('restored')
  end

  def self.move_camera
    @model.active_view.camera = Sketchup::Camera.new([2.m,-15.m,10.m], [4.5.m,2.2.m,0.5.m], [0,0,1])
    @model.active_view.camera.fov = 48
    record('moved-camera', BogdanD5Sync::Scene.camera(@model.active_view))
  end

  def self.reopen_embedded
    path = @model.path
    BogdanD5Sync.controller.stop
    raise 'Could not reopen the disposable fixture.' unless Sketchup.open_file(path)
    @model = Sketchup.active_model
    capture('reopened-embedded')
  end
end

D5MaterialAcceptance.build unless defined?(D5MaterialAcceptance::SKIP_BUILD) && D5MaterialAcceptance::SKIP_BUILD
