# Development-only: fresh process, private COPY, live D5 identity supplied by
# the operator. Never save the model. Restore its materials in D5 before exit.
require 'json'
module D5LiveRepaintRegression
  def self.record(extra = {})
    File.open(File.join(@folder, 'live-result.json'), 'wb') do |file|
      file.write(JSON.pretty_generate({'cycles'=>@cycles || 0, 'stage'=>@stage,
        'pass'=>false, 'fibers'=>@fibers || [], 'triangles'=>@triangles}.merge(extra)))
    end
  end

  def self.start
    copy = ENV.fetch('D5_REGRESSION_COPY')
    identity = ENV.fetch('D5_REGRESSION_IDENTITY')
    raise 'Test copy must differ from the original' if File.expand_path(copy) == File.expand_path(identity)
    @folder = File.dirname(copy)
    model = Sketchup.active_model
    raise 'Fresh disposable process required' unless model.path.empty? && !model.modified?
    raise 'Could not open disposable copy' unless Sketchup.open_file(copy)
    @model = Sketchup.active_model
    @materials = @model.materials.to_a
    @colors = @materials.map { |material| [material, material.color] }
    @paint = @materials.find { |material| !material.texture }
    @textured = @materials.find { |material| material.texture }
    raise 'Fixture requires plain and textured materials' unless @paint && @textured
    folder = BogdanD5Sync::Scene.companion(copy)
    FileUtils.mkdir_p(folder)
    @textures = folder
    @transport = BogdanD5Sync::Transport.new(identity, true, false, 'texture_folder'=>folder)
    @transport.send('op'=>'info')
    @stage = 'connecting'
    @cycles, @polls, @fibers = 0, 0, []
    @started = Time.now.to_f
    @model.materials.current = @paint
    Sketchup.send_action('selectPaintTool:')
    @timer = UI.start_timer(0.025, true) { tick }
    record
  rescue StandardError => error
    record('error'=>error.message, 'backtrace'=>error.backtrace) if @folder
  end

  def self.send_scene
    @stage = 'capture'
    record
    scene = BogdanD5Sync::Scene.new(@model, @textures).capture
    @triangles = scene['objects'].inject(0) { |sum, object| sum + object['triangles'].length }
    @transport.send('op'=>'snapshot', 'scene'=>scene)
    @stage = @restoring ? 'restoring_original_materials_in_D5' : 'live_snapshot'
    record
  end

  def self.tick
    fiber = Fiber.current.object_id
    @fibers << fiber unless @fibers.include?(fiber)
    raise 'Regression timeout' if Time.now.to_f - @started > 300
    @polls += 1
    GC.start if @polls % 11 == 0
    @transport.poll.each do |reply|
      raise reply.inspect unless reply['ok']
      if reply['op'] == 'info'
        raise 'A ready D5 project is required' unless reply['d5_status'].to_s.include?('InProject')
        send_scene
      elsif reply['op'] == 'snapshot'
        File.open(File.join(@folder, 'live-timings.jsonl'), 'ab') { |file| file.write(JSON.generate(reply) + "\n") }
        if @restoring
          UI.stop_timer(@timer)
          @transport.stop
          @stage = 'complete'
          record('pass'=>true, 'original_materials_restored'=>true, 'polls'=>@polls)
          return
        end
        @cycles += 1
        @model.start_operation('Disposable live repaint test', true)
        if @cycles >= Integer(ENV.fetch('D5_REGRESSION_CYCLES', '10'))
          @colors.each { |material, color| material.color = color }
          @restoring = true
        else
          material = @cycles.even? ? @paint : @textured
          material.color = @cycles.even? ? 'white' : 'blue'
        end
        @model.commit_operation
        send_scene
      end
    end
  rescue StandardError => error
    UI.stop_timer(@timer) if @timer
    @transport.stop if @transport
    record('error'=>error.message, 'backtrace'=>error.backtrace)
  end
end
UI.start_timer(2, false) { D5LiveRepaintRegression.start }
