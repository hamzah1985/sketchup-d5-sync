# SPDX-License-Identifier: GPL-3.0-or-later
require 'json'
require 'fileutils'
module BogdanD5Sync
  module Settings
    DEFAULTS = {'texture_root' => '', 'd5_path' => '', 'camera_fps' => 60,
      'delay_ms' => 750, 'automatic' => true, 'camera' => true,
      'defer_nested' => true, 'opacity' => 'opaque'}.freeze
    def self.path
      File.join(ENV['LOCALAPPDATA'] || ENV['APPDATA'] || Dir.home, 'BogdanD5Sync', 'settings.json')
    end
    def self.validate(input)
      values = DEFAULTS.merge(input.select { |key, _| DEFAULTS.key?(key) })
      values['camera_fps'] = Integer(values['camera_fps'])
      values['delay_ms'] = Integer(values['delay_ms'])
      raise ArgumentError, 'Camera rate must be 15–60 Hz.' unless (15..60).include?(values['camera_fps'])
      raise ArgumentError, 'Update delay must be 250–5000 ms.' unless (250..5000).include?(values['delay_ms'])
      %w[automatic camera defer_nested].each do |key|
        raise ArgumentError, 'Invalid switch: ' + key unless [true, false].include?(values[key])
      end
      raise ArgumentError, 'Invalid opacity mode.' unless %w[opaque sketchup].include?(values['opacity'])
      %w[texture_root d5_path].each do |key|
        value = values[key].to_s.strip
        values[key] = value.empty? ? '' : File.expand_path(value)
      end
      unless values['d5_path'].empty? || File.file?(File.join(values['d5_path'], 'd5_launcher.exe'))
        raise ArgumentError, 'D5 folder must contain d5_launcher.exe.'
      end
      values
    end
    def self.current
      return @values if @values
      @values = validate(File.file?(path) ? JSON.parse(File.read(path)) : {})
    rescue StandardError => error
      warn('D5 Sync settings: ' + error.message)
      @values = DEFAULTS.dup
    end
    def self.save(input)
      values = validate(input)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = path + '.tmp'
      File.open(temporary, 'wb') { |file| file.write(JSON.pretty_generate(values)) }
      File.rename(temporary, path)
      @values = values
    end
    def self.texture_folder(model_path)
      current['texture_root'].empty? ? Scene.companion(model_path) : current['texture_root']
    end
    def self.show
      if @dialog
        @dialog.show
        return
      end
      style = defined?(UI::HtmlDialog::STYLE_UTILITY) ? UI::HtmlDialog::STYLE_UTILITY : UI::HtmlDialog::STYLE_DIALOG
      @dialog = UI::HtmlDialog.new(:dialog_title => 'D5 Sync Settings', :width => 480,
        :height => 610, :resizable => true, :style => style)
      @dialog.set_file(File.join(__dir__, 'settings.html'))
      @dialog.add_action_callback('ready') { |_context| publish }
      @dialog.add_action_callback('browse') do |_context, key|
        if %w[texture_root d5_path].include?(key)
          chosen = UI.select_directory(:title => key == 'texture_root' ? 'Choose Shared Texture Folder' : 'Choose D5 Render Folder')
          @dialog.execute_script('setPath(' + JSON.generate(key) + ',' + JSON.generate(chosen) + ')') if chosen
        end
      end
      @dialog.add_action_callback('save') do |_context, json|
        begin
          save(JSON.parse(json))
          controller = BogdanD5Sync.controller
          # Path/native settings belong to a worker session. Disconnect safely;
          # reconnect is explicit so no second D5 project is opened unexpectedly.
          controller.stop
          publish('Saved. Connect to D5 to apply the settings.')
        rescue StandardError => error
          warn('D5 Sync settings: ' + error.message)
          publish(error.message)
        end
      end
      @dialog.set_on_closed { @dialog = nil }
      @dialog.show
    end
    def self.publish(message = '')
      @dialog.execute_script('loadSettings(' + JSON.generate(current) + ',' + JSON.generate(message) + ')')
    end
  end
end
