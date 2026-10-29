require 'minitest/autorun'
module UI
  class << self; attr_accessor :callbacks; end
  self.callbacks = []
  def self.start_timer(_delay, _repeat, &block); callbacks << block; end
end
require_relative '../bogdan_d5_sync/progress'
class D5ProgressTest < Minitest::Test
  class Dialog
    attr_reader :closed
    def execute_script(_code); end
    def close; @closed = true; end
  end
  def setup
    UI.callbacks.clear
    @dialog = Dialog.new
    BogdanD5Sync::Progress.instance_variable_set(:@dialog, @dialog)
  end
  def teardown
    BogdanD5Sync::Progress.instance_variable_set(:@dialog, nil)
  end
  def test_completion_closes_but_new_work_cancels_old_close
    BogdanD5Sync::Progress.update('Model sent; skipped 294 collapsed triangles')
    UI.callbacks.pop.call
    assert @dialog.closed
    @dialog = Dialog.new
    BogdanD5Sync::Progress.instance_variable_set(:@dialog, @dialog)
    BogdanD5Sync::Progress.update('Model sent to D5')
    BogdanD5Sync::Progress.update('Preparing new geometry')
    UI.callbacks.pop.call
    refute @dialog.closed
    BogdanD5Sync::Progress.update('Connection failed')
    assert_empty UI.callbacks
  end
end
