require 'minitest/autorun'
require 'tmpdir'
require_relative '../bogdan_d5_sync/settings'
class D5SettingsTest < Minitest::Test
  def test_profile_save_reload_and_validation
    original = ENV['LOCALAPPDATA']
    Dir.mktmpdir do |folder|
      ENV['LOCALAPPDATA'] = folder
      BogdanD5Sync::Settings.instance_variable_set(:@values, nil)
      BogdanD5Sync::Settings.save({'camera_fps'=>30, 'texture_root'=>folder, 'automatic'=>false})
      BogdanD5Sync::Settings.instance_variable_set(:@values, nil)
      assert_equal 30, BogdanD5Sync::Settings.current['camera_fps']
      refute BogdanD5Sync::Settings.current['automatic']
      assert_equal File.expand_path(folder), BogdanD5Sync::Settings.texture_folder('unused.skp')
      assert_raises(ArgumentError) { BogdanD5Sync::Settings.save({'camera_fps'=>0}) }
      assert_raises(ArgumentError) { BogdanD5Sync::Settings.save({'delay_ms'=>-1}) }
      assert_raises(ArgumentError) { BogdanD5Sync::Settings.save({'d5_path'=>folder}) }
      assert_raises(ArgumentError) { BogdanD5Sync::Settings.save({'automatic'=>'true'}) }
      assert_equal 30, JSON.parse(File.read(BogdanD5Sync::Settings.path))['camera_fps']
    end
  ensure
    ENV['LOCALAPPDATA'] = original
    BogdanD5Sync::Settings.instance_variable_set(:@values, nil)
  end
end
