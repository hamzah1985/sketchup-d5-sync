# SPDX-License-Identifier: GPL-3.0-or-later
require 'sketchup.rb'
Sketchup.require(File.join(__dir__, 'scene'))
Sketchup.require(File.join(__dir__, 'transport'))
Sketchup.require(File.join(__dir__, 'settings'))
Sketchup.require(File.join(__dir__, 'progress'))

module BogdanD5Sync
  class ModelObserver < Sketchup::ModelObserver
    def initialize(controller)
      @controller = controller
    end
    def onTransactionStart(_model); @controller.transaction_started; end
    def onTransactionCommit(_model); @controller.transaction_finished(true); end
    def onTransactionUndo(_model); @controller.dirty; end
    def onTransactionRedo(_model); @controller.dirty; end
    def onTransactionAbort(_model); @controller.transaction_finished(false); end
    def onSaveModel(_model); @controller.dirty; end
    def onActivePathChanged(_model); @controller.context_changed; end
  end

  class AppObserver < Sketchup::AppObserver
    def onQuit; BogdanD5Sync.controller.stop; end
    def onNewModel(_model); BogdanD5Sync.controller.stop; end
    def onOpenModel(_model); BogdanD5Sync.controller.stop; end
  end

  class Controller
    attr_reader :state, :last_reply, :last_error, :transport

    def initialize
      @state = 'Disconnected'
      @last_reply = nil
      @last_error = nil
      @stats = {'snapshots' => 0, 'cameras' => 0}
    end

    def connect(legacy_identity = false)
      return if @transport
      raise ArgumentError, 'This prototype currently requires Windows and SketchUp 2020 or newer.' unless Sketchup.platform == :platform_win && Sketchup.version.to_i >= 20
      @model = Sketchup.active_model
      if @model.path.empty?
        chosen = UI.savepanel('Save SketchUp Model for D5 Sync', nil, 'D5 Sync Model.skp')
        return unless chosen
        chosen += '.skp' if File.extname(chosen).empty?
        raise ArgumentError, 'Choose a .skp filename.' unless File.extname(chosen).downcase == '.skp'
        return unless @model.save(chosen)
      end
      @path = File.expand_path(@model.path)
      @settings = Settings.current.dup
      @texture_folder = Settings.texture_folder(@path)
      FileUtils.mkdir_p(@texture_folder)
      @transport = Transport.new(@path, true, legacy_identity, @settings.merge('texture_folder' => @texture_folder))
      @observer = ModelObserver.new(self)
      @model.add_observer(@observer)
      @dirty, @last_camera, @last_scene = true, nil, nil
      @scene_cache = nil
      @force_sync = true
      @pending, @ready, @next_info = nil, false, 0
      @last_error = nil
      @started_at = Time.now.to_f
      @dirty_at = @started_at
      set_state('Connecting to D5')
      Progress.show('Starting D5; open or create a project if prompted')
      @timer = UI.start_timer(1.0 / @settings['camera_fps'], true) { tick }
      send_request({'op' => 'info'})
    rescue StandardError => error
      fail_connection(error)
    end

    def dirty
      @dirty = true
      @dirty_at = Time.now.to_f
    end

    def context_changed
      # Entering a group changes the editing context, not exported geometry.
      # On exit, allow queued edits to settle before reading the whole model.
      @dirty_at = Time.now.to_f if @dirty
    end

    def transaction_started
      @operation_active = true
    end

    def transaction_finished(committed)
      @operation_active = false
      dirty if committed
    end

    def sync_now
      return connect unless @transport
      @last_camera, @last_scene = nil, nil
      @force_sync = true
      dirty
      @dirty_at = 0
    end

    def tick
      return if @ticking
      @ticking = true
      begin
        tick_once
      ensure
        @ticking = false
      end
    end

    def tick_once
      return unless @transport
      if Sketchup.active_model != @model || File.expand_path(@model.path) != @path
        stop
        set_state('Model changed; reconnect to D5')
        return
      end
      @transport.poll.each { |reply| handle_reply(reply) }
      return unless @transport
      now = Time.now.to_f
      if @pending && @pending != 'camera' && @transport.respond_to?(:progress)
        stage = @transport.progress
        set_state(stage) if stage && stage != @state
      end
      raise IOError, 'D5 did not respond within 60 seconds. Open a D5 project and reconnect.' if @pending && now - @pending_at > 60
      return if @pending
      unless @ready
        if now >= @next_info
          @next_info = now + 1.0
          send_request({'op' => 'info'})
        end
        return
      end
      settings = @settings || Settings::DEFAULTS
      if @dirty && !@operation_active && (@force_sync || settings['automatic']) && now - @dirty_at >= (@force_sync ? 0 : settings['delay_ms'] / 1000.0) && (@force_sync || !settings['defer_nested'] || !@model.active_path || @scene_cache)
        unless @capture_announced
          @capture_announced = true
          set_state('Preparing geometry and extracting textures')
          return
        end
        # Capture only on the SketchUp GUI thread, after a transaction settles.
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        trace('capture_started')
        exporter = Scene.new(@model, @texture_folder)
        scoped = @model.active_path && @scene_cache && settings['defer_nested'] && !@force_sync
        scene = scoped ? exporter.capture_context(@scene_cache) : exporter.capture
        @scene_cache = scene
        @stats['capture_scope'] = scoped ? 'edited component instances and materials' : 'full model'
        scene['opacity_mode'] = settings['opacity']
        @stats['capture_ms'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        trace('capture_finished')
        @dirty = false
        @capture_announced = false
        @force_sync = false
        # The worker compares cached mesh/material fingerprints. Avoid formatting
        # the entire model as JSON here and repeating it in the I/O thread.
        send_request({'op' => 'snapshot', 'scene' => scene})
        set_state('Packing and transferring the model; please wait')
        return
      end
      return unless settings['camera']
      camera = Scene.camera(@model.active_view)
      signature = JSON.generate(camera)
      if signature != @last_camera
        @sending_camera = signature
        send_request({'op' => 'camera', 'camera' => camera})
      end
    rescue StandardError => error
      fail_connection(error)
    end

    def handle_reply(reply)
      @last_reply = reply
      @pending = nil
      raise IOError, reply['error'].to_s unless reply['ok']
      case reply['op']
      when 'info'
        status = reply['d5_status'].to_s
        @ready = status.include?('InProject') || (status.include?('Ready') && !status.include?('Not'))
        set_state(@ready ? 'D5 ready; preparing model' : 'Waiting for a D5 project')
      when 'snapshot'
        trace('snapshot_acknowledged')
        @stats['snapshots'] += 1
        @stats['last_snapshot'] = reply
        skipped = reply['skipped_degenerate_triangles'].to_i
        @stats['skipped_degenerate_triangles'] = skipped
        set_state(skipped > 0 ? "Model sent; skipped #{skipped} collapsed triangles" : 'Model sent to D5; rendering may take a moment')
      when 'camera'
        @last_camera = @sending_camera
        @stats['cameras'] += 1
        @stats['last_camera_round_trip_ms'] = (Time.now.to_f - @pending_at) * 1000.0
      end
    end

    def stop
      UI.stop_timer(@timer) if @timer
      @timer = nil
      @model.remove_observer(@observer) if @model && @observer
      @observer = nil
      @transport.stop if @transport
      @transport = nil
      @pending, @ready = nil, false
      @force_sync = false
      @operation_active = false
      @capture_announced = false
      @scene_cache = nil
      set_state('Disconnected')
    end

    def diagnostics
      {'state' => @state, 'error' => @last_error, 'reply' => @last_reply,
       'acknowledged_updates' => @stats.dup,
       'worker_pid' => @transport && @transport.pid,
       'diagnostics_folder' => @transport ? @transport.folder : Transport.data_root}
    end

    private

    def trace(event)
      return unless @transport && @transport.respond_to?(:folder)
      record = {'time'=>Time.now.to_f, 'event'=>event, 'main_thread'=>Thread.current == Thread.main,
                'fiber'=>Fiber.current.object_id, 'tool'=>@model.tools.active_tool_name}
      File.open(File.join(@transport.folder, 'host-events.jsonl'), 'ab') { |file| file.write(JSON.generate(record) + "\n") }
    rescue StandardError => error
      warn('D5 Sync diagnostic write: ' + error.message)
    end

    def send_request(request)
      @pending = request['op']
      @pending_at = Time.now.to_f
      @transport.send(request)
    end

    def set_state(state)
      @state = state
      BogdanD5Sync.update_tooltips(state)
      Sketchup.status_text = 'D5 Sync: ' + state + '.'
      Progress.update(state)
    end

    def fail_connection(error)
      @last_error = error.message
      warn("D5 Sync: #{error.class}: #{error.message}\n#{error.backtrace.join("\n")}")
      stop
      set_state('Connection failed')
      UI.messagebox("D5 Sync: #{error.message}\n\nDiagnostics: #{Transport.data_root}")
    end
  end

  def self.controller
    @controller ||= Controller.new
  end

  def self.update_tooltips(state)
    @connect_command.tooltip = 'D5 Sync — ' + state if @connect_command
  end

  def self.show_toolbar
    @toolbar.show if @toolbar
  end

  unless file_loaded?(__FILE__)
    @connect_command = UI::Command.new('Connect to D5') { controller.connect }
    sync_command = UI::Command.new('Sync Now') { controller.sync_now }
    disconnect_command = UI::Command.new('Disconnect D5') { controller.stop }
    settings_command = UI::Command.new('D5 Sync Settings') { Settings.show }
    @toolbar = UI::Toolbar.new('D5 Sync — Experimental')
    [@connect_command, sync_command, disconnect_command, settings_command].zip(%w[logo sync disconnect settings]).each do |command, icon|
      command.small_icon = File.join(__dir__, 'icons', icon + '.svg')
      command.large_icon = command.small_icon
      command.tooltip = command.menu_text
      command.status_bar_text = command.menu_text + '.'
      @toolbar.add_item(command)
    end
    menu = UI.menu('Extensions').add_submenu('D5 Sync — Experimental')
    menu.add_item(@connect_command)
    menu.add_item(sync_command)
    menu.add_item(disconnect_command)
    menu.add_item(settings_command)
    menu.add_item('Show Sync Progress') { Progress.show(controller.state) }
    menu.add_item('Connect Using Legacy Blender Identity') { controller.connect(true) }
    menu.add_separator
    menu.add_item('Show Toolbar') { show_toolbar }
    menu.add_item('Connection Status') { UI.messagebox(JSON.pretty_generate(controller.diagnostics)) }
    @app_observer = AppObserver.new
    Sketchup.add_observer(@app_observer)
    @toolbar.show
    file_loaded(__FILE__)
  end
end
