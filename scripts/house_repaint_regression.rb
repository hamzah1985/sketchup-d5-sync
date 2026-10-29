# Local-only private-model regression. Never uploads or saves edits to the copy.
require 'json'
module D5HouseRegression
  def self.record(values)
    File.open(File.join(@folder,'result.json'),'wb') { |f| f.write(JSON.pretty_generate(values.merge('cycles'=>@cycles || 0))) }
  end
  def self.start
    config = JSON.parse(File.read(File.join(__dir__,'house_regression_local.json')))
    document = config.fetch('copy')
    @folder = File.dirname(document)
    model = Sketchup.active_model
    raise 'Fresh disposable process required' unless model.path.empty? && !model.modified?
    raise 'Cannot open private test copy' unless Sketchup.open_file(document)
    @model = Sketchup.active_model
    @paint = @model.materials.find { |m| !m.texture }
    raise 'No plain material for repaint check' unless @paint
    @textures = BogdanD5Sync::Scene.companion(document); FileUtils.mkdir_p(@textures)
    record('stage'=>'first_capture','pass'=>false)
    @scene = BogdanD5Sync::Scene.new(@model,@textures).capture
    @triangles = @scene['objects'].inject(0) { |sum,obj| sum+obj['triangles'].length }
    @transport = BogdanD5Sync::Transport.new(document,false)
    @transport.send({'op'=>'info'})
    @cycles = 0; @polls = 0; @started = Time.now.to_f
    @model.materials.current = @paint
    Sketchup.send_action('selectPaintTool:')
    @timer = UI.start_timer(0.015,true) { tick }
  rescue StandardError => error
    record('pass'=>false,'error'=>error.message,'backtrace'=>error.backtrace) if @folder
  end
  def self.tick
    raise 'House regression timed out' if Time.now.to_f - @started > 240
    @polls += 1
    GC.start if @polls % 13 == 0
    @transport.poll.each do |reply|
      raise reply.inspect unless reply['ok']
      if reply['op']=='snapshot'
        @cycles += 1
        if @cycles >= 5
          UI.stop_timer(@timer); @transport.stop
          record('pass'=>true,'triangles'=>@triangles,'stage'=>'complete','sketchup'=>Sketchup.version)
          return
        end
      end
      @model.start_operation('Private copy material regression',true)
      @paint.color = @cycles.even? ? 'white' : 'blue'
      @model.commit_operation
      record('pass'=>false,'stage'=>'texture_and_geometry_capture','triangles'=>@triangles)
      @scene = BogdanD5Sync::Scene.new(@model,@textures).capture
      @transport.send({'op'=>'snapshot','scene'=>@scene})
      record('pass'=>false,'stage'=>'packing_and_native_worker','triangles'=>@triangles)
    end
  rescue StandardError => error
    UI.stop_timer(@timer) if @timer
    @transport.stop if @transport
    record('pass'=>false,'error'=>error.message,'backtrace'=>error.backtrace)
  end
end
UI.start_timer(2,false) { D5HouseRegression.start }
