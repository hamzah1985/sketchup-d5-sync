require 'minitest/autorun'
require_relative '../bogdan_d5_sync/packet'
class D5IncrementalPacketTest < Minitest::Test
  def test_large_packet_yields_and_stays_on_the_calling_thread
    request={'op'=>'snapshot','scene'=>{'objects'=>[{'id'=>'large',
      'vertices'=>Array.new(10000) { |i| [i.to_f,0.0,0.0] },
      'triangles'=>[[0,1,2]]}]}}
    before=Thread.list.map { |thread| thread.object_id }
    encoder = nil
    Fiber.stub(:new, proc { raise 'Packing must not create a fiber' }) do
      encoder=BogdanD5Sync::Packet::Encoder.new(request)
      encoder.advance(0)
      refute encoder.complete?, 'Packing must yield between bounded numeric blocks'
      100.times do
        break if encoder.complete?
        GC.start
        encoder.advance(0)
      end
    end
    assert encoder.complete?
    assert_equal before, Thread.list.map { |thread| thread.object_id }
    bytes=encoder.chunks.join
    header,body=bytes.split("\n",2)
    assert_equal JSON.parse(header)['payload_bytes'],body.bytesize
    assert_equal 10000*3*4+3*4,body.bytesize
  end

  def test_empty_optional_fields_and_multiple_objects_keep_wire_order
    request = {'op'=>'snapshot','scene'=>{'objects'=>[
      {'id'=>'empty','vertices'=>[], 'triangles'=>[], 'uvs'=>[]},
      {'id'=>'small','vertices'=>[[1,2,3]], 'normals'=>[[0,0,1]], 'uvs'=>[[0.2,0.3]]}
    ]}}
    expected = BogdanD5Sync::Packet.build(request).join
    assert_equal expected, BogdanD5Sync::Packet.encode(request).join
  end
end
