# Development-only startup harness for a separate, unsaved SketchUp session.
require 'json'
UI.start_timer(2, false) do
  begin
    model = Sketchup.active_model
    raise 'Use a fresh disposable model' unless model.path.empty? && !model.modified?
    load File.join(__dir__, 'native_acceptance.rb')
    BogdanD5Sync::Settings.show
    output = File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'acceptance', 'settings-ui.json')
    File.open(output, 'wb') { |file| file.write(JSON.pretty_generate({'pass'=>true,
      'sketchup'=>Sketchup.version, 'settings'=>BogdanD5Sync::Settings.current,
      'model_unchanged'=>!model.modified?})) }
  rescue StandardError => error
    warn("D5 settings acceptance: #{error.message}\n#{error.backtrace.join("\n")}")
  end
end
