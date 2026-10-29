require 'minitest/autorun'
$LOADED_FEATURES << 'sketchup.rb'
module Sketchup
  class ModelObserver; end
  class AppObserver; end
  def self.require(path); Kernel.require(path); end
  class << self; attr_accessor :active_model, :status_text; end
end
def file_loaded?(_path); true; end
require_relative '../bogdan_d5_sync/main'

class D5EditingTest < Minitest::Test
  Model = Struct.new(:path, :active_path, :active_view)
  class Transport
    attr_reader :requests
    def initialize; @requests = []; end
    def poll; []; end
    def send(request); @requests << request; end
  end
  def setup
    @model = Model.new(File.expand_path('fixture.skp'), ['component'], Object.new)
    Sketchup.active_model = @model
    @controller = BogdanD5Sync::Controller.new
    @transport = Transport.new
    {'model'=>@model, 'path'=>@model.path, 'transport'=>@transport, 'ready'=>true,
     'dirty'=>true, 'dirty_at'=>0, 'last_camera'=>'{}'}.each { |k,v| @controller.instance_variable_set('@'+k,v) }
  end
  def test_entering_component_does_not_mark_clean_model_dirty
    @controller.instance_variable_set('@dirty', false)
    BogdanD5Sync::ModelObserver.new(@controller).onActivePathChanged(@model)
    refute @controller.instance_variable_get('@dirty')
  end
  def test_nested_edit_defers_mesh_capture_but_still_sends_camera
    @controller.instance_variable_set('@last_camera', nil)
    BogdanD5Sync::Scene.stub(:camera, {}) do
      BogdanD5Sync::Scene.stub(:new, proc { raise 'Unexpected full model capture' }) { @controller.tick }
    end
    assert_equal ['camera'], @transport.requests.map { |r| r['op'] }
    assert @controller.instance_variable_get('@dirty')
  end
  def test_exit_sends_queued_edits_and_sync_now_overrides_context
    [false, true].each do |force|
      @model.active_path = force ? ['component'] : nil
      @controller.instance_variable_set('@pending', nil)
      @controller.instance_variable_set('@dirty', true)
      @controller.instance_variable_set('@dirty_at', 0)
      @controller.instance_variable_set('@force_sync', force)
      @controller.instance_variable_set('@capture_announced', true)
      scene = Object.new
      def scene.capture; {'objects'=>[]}; end
      BogdanD5Sync::Scene.stub(:new, scene) { @controller.tick }
      assert_equal 'snapshot', @transport.requests.last['op']
      refute @controller.instance_variable_get('@dirty')
    end
  end
  def test_reentrant_tick_does_not_start_another_capture
    @controller.instance_variable_set('@ticking', true)
    @controller.tick
    assert_empty @transport.requests
    assert @controller.instance_variable_get('@ticking')
  end
  def test_open_transaction_defers_capture_and_abort_does_not_dirty_clean_scene
    @model.active_path = nil
    observer = BogdanD5Sync::ModelObserver.new(@controller)
    observer.onTransactionStart(@model)
    BogdanD5Sync::Scene.stub(:camera, {}) do
      BogdanD5Sync::Scene.stub(:new, proc { raise 'Captured uncommitted geometry' }) { @controller.tick }
    end
    assert_empty @transport.requests
    @controller.instance_variable_set('@dirty', false)
    observer.onTransactionAbort(@model)
    refute @controller.instance_variable_get('@dirty')
    refute @controller.instance_variable_get('@operation_active')
  end
  def test_preparation_stage_is_announced_before_expensive_capture
    @model.active_path = nil
    @controller.tick
    assert_equal 'Preparing geometry and extracting textures', @controller.state
    assert_empty @transport.requests
    assert @controller.instance_variable_get('@capture_announced')
  end
end
