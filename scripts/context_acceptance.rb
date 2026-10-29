require 'json'
UI.start_timer(2, false) do
  begin
    model = Sketchup.active_model
    raise 'Use a fresh disposable model' unless model.path.empty? && !model.modified?
    model.start_operation('Scoped sync fixture', true)
    paint = model.materials.add('Scoped paint')
    paint.color = 'red'
    definition = model.definitions.add('Scoped component')
    face = definition.entities.add_face([0,0,0],[1.m,0,0],[0,1.m,0])
    face.material = paint
    a = model.entities.add_instance(definition, Geom::Transformation.new)
    model.entities.add_instance(definition, Geom::Transformation.translation([3.m,0,0]))
    outside = model.entities.add_group
    other = outside.entities.add_face([0,3.m,0],[1.m,3.m,0],[0,4.m,0])
    other.material = paint
    model.commit_operation
    folder = File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'context-acceptance')
    FileUtils.mkdir_p(folder)
    previous = BogdanD5Sync::Scene.new(model, folder).capture
    model.active_path = [a]
    model.start_operation('Paint inside component', true)
    paint.color = 'blue'
    face.material = nil
    model.commit_operation
    scoped = BogdanD5Sync::Scene.new(model, folder).capture_context(previous)
    full = BogdanD5Sync::Scene.new(model, folder).capture
    sort_scene = proc do |scene|
      {'objects'=>scene['objects'].sort_by { |o| o['id'] },
       'materials'=>scene['materials'].sort_by { |m| m['id'] }}
    end
    raise 'Scoped update differs from full capture' unless sort_scene.call(scoped) == sort_scene.call(full)
    model.active_path = nil
    record = {'pass'=>true, 'checks'=>['Repaint in active component matches full capture',
      'Shared component placements updated', 'Global material change outside edit context refreshed'],
      'sketchup'=>Sketchup.version}
    File.open(File.join(folder, 'result.json'), 'wb') { |file| file.write(JSON.pretty_generate(record)) }
  rescue StandardError => error
    folder = File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'context-acceptance')
    FileUtils.mkdir_p(folder)
    File.open(File.join(folder, 'result.json'), 'wb') { |file| file.write(JSON.pretty_generate({'pass'=>false,'error'=>error.message})) }
    warn("Scoped D5 acceptance: #{error.message}\n#{error.backtrace.join("\n")}")
  end
end
