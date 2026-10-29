# Development-only regression in a separately launched, unsaved test session.
require 'json'
module D5RepaintStress
  def self.record(extra = {})
    value = {'pass'=>false,'cycles'=>@cycles || 0,'stage'=>@stage,'sketchup'=>Sketchup.version}.merge(extra)
    File.open(File.join(@folder, 'result.json'), 'wb') { |f| f.write(JSON.pretty_generate(value)) }
  end
  def self.start
    suffix = ENV['D5_STRESS_VARIANT'] == 'baseline-thread' ? '-baseline-thread' : ''
    @folder = File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'repaint-stress-20261029' + suffix)
    FileUtils.mkdir_p(@folder)
    @model = Sketchup.active_model
    raise 'A fresh disposable session is required' unless @model.path.empty? && !@model.modified?
    @model.start_operation('Repaint stress fixture',true)
    figure = @model.entities.grep(Sketchup::ComponentInstance).first
    if figure
      15.times { |i| @model.entities.add_instance(figure.definition,Geom::Transformation.translation([(i+1)*2.m,0,0])) }
    end
    @part = @model.entities.add_group
    @face = @part.entities.add_face([0,0,0],[1.m,0,0],[1.m,1.m,0],[0,1.m,0])
    @paint = @model.materials.add('Regression paint')
    @paint.texture = File.join(__dir__, 'checker.png')
    @face.material = @paint
    @model.commit_operation
    document = File.join(@folder, 'repaint-fixture.skp')
    raise 'Cannot save disposable fixture' unless @model.save(document)
    @textures = BogdanD5Sync::Scene.companion(document)
    FileUtils.mkdir_p(@textures)
    @cache = BogdanD5Sync::Scene.new(@model,@textures).capture
    @triangles = @cache['objects'].inject(0) { |sum,o| sum+o['triangles'].length }
    @transport = BogdanD5Sync::Transport.new(document,false)
    @transport.send({'op'=>'info'})
    @stage = 'connecting'; @cycles = 0; @polls = 0; @started = Time.now.to_f
    @timer = UI.start_timer(0.01,true) { tick }
    record('triangles'=>@triangles)
  rescue StandardError => error
    record('error'=>error.message,'backtrace'=>error.backtrace) if @folder
  end
  def self.repaint
    @model.active_path = @cycles.even? ? [@part] : nil
    @model.start_operation('Paint regression cycle',true)
    @paint.color = @cycles.even? ? 'red' : 'blue'
    @face.material = @cycles % 3 == 0 ? nil : @paint
    @model.commit_operation
    exporter = BogdanD5Sync::Scene.new(@model,@textures)
    @cache = @model.active_path ? exporter.capture_context(@cache) : exporter.capture
    @stage = 'packing_and_native_snapshot'
    @transport.send({'op'=>'snapshot','scene'=>@cache})
    record('triangles'=>@triangles)
  end
  def self.tick
    @polls += 1
    raise 'Regression timeout' if Time.now.to_f - @started > 180
    GC.start if @polls % 7 == 0
    @transport.poll.each do |reply|
      raise reply.inspect unless reply['ok']
      if reply['op']=='snapshot'
        @cycles += 1
        if @cycles >= 30
          @stage = 'complete'
          UI.stop_timer(@timer)
          @model.active_path = nil
          @transport.stop
          record('pass'=>true,'triangles'=>@triangles,'polls'=>@polls)
          return
        end
      end
      repaint
    end
  rescue StandardError => error
    UI.stop_timer(@timer) if @timer
    @transport.stop if @transport
    record('error'=>error.message,'backtrace'=>error.backtrace)
  end
end
UI.start_timer(2,false) { D5RepaintStress.start }
