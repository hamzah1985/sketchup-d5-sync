require 'minitest/autorun'
require_relative '../bogdan_d5_sync/transport'

class D5NonblockingTransportTest < Minitest::Test
  class FragmentedSocket
    attr_reader :written
    def initialize
      @written, @calls, @replied = ''.b, 0, false
      @fragments = []
    end
    def write_nonblock(bytes)
      @calls += 1
      raise IO::EAGAINWaitWritable if @calls % 4 == 0
      size = [bytes.bytesize, 7].min
      @written << bytes.byteslice(0, size)
      size
    end
    def read_nonblock(_length)
      if @written.end_with?("\n") && !@replied
        @replied = true
        @fragments = ['{"ok":true,', '"op":"camera"}', "\n"]
      end
      raise IO::EAGAINWaitReadable if @fragments.empty?
      @fragments.shift
    end
  end

  def test_partial_writes_backpressure_and_fragmented_json_reply_keep_exact_frame
    socket = FragmentedSocket.new
    transport = BogdanD5Sync::Transport.allocate
    {'socket' => socket, 'closed' => false, 'connected' => true,
     'incoming' => Queue.new, 'outgoing' => Queue.new,
     'receive_buffer' => ''.b}.each { |key, value| transport.instance_variable_set('@'+key, value) }
    request = {'op' => 'camera', 'camera' => {'position' => [1,2,3], 'name' => 'test camera'}}
    transport.send(request)
    reply = nil
    100.times do
      reply = transport.poll.first
      break if reply
    end
    assert reply, 'Backpressured frame never completed'
    assert_equal request, JSON.parse(socket.written)
    assert_equal 'camera', reply['op']
    assert reply['ok']
    assert_equal socket.written.bytesize, reply['transport']['request_bytes']
    assert_operator reply['transport']['round_trip_ms'], :>=, 0
    assert_empty transport.poll
  end
end
