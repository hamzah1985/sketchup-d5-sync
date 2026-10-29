require 'json'
require 'fileutils'
require 'timeout'
require_relative '../bogdan_d5_sync/transport'
module UI
  def self.start_timer(delay, _repeat, &block)
    Thread.new { sleep(delay); block.call }
  end
end
folder = File.join(ENV['LOCALAPPDATA'], 'BogdanD5Sync', 'acceptance')
FileUtils.mkdir_p(folder)
document = File.join(folder, 'transport-fixture.skp')
File.write(document, 'offline fixture')
transport = BogdanD5Sync::Transport.new(document, false)
begin
  transport.send({'op' => 'info'})
  reply = nil
  Timeout.timeout(30) do
    until reply
      reply = transport.poll.first
      sleep(0.05) unless reply
    end
  end
  raise reply.inspect unless reply['ok'] && reply['op'] == 'info' && !reply['blender_imported']
  raise 'Expected actual SKP connection identity' unless reply['source_path'].downcase.end_with?('.skp')
  info = reply
  object = {'id' => 'triangle', 'vertices' => [[0,0,0],[1,0,0],[0,1,0]],
    'normals' => [[0,0,1]] * 3, 'triangles' => [[0,1,2]], 'uvs' => [[0,0],[1,0],[0,1]], 'material_id'=>'paint'}
  transport.send({'op' => 'snapshot', 'scene' => {'objects' => [object],
    'materials'=>[{'id'=>'paint','color'=>'#FFFFFF'}]}})
  reply = nil
  Timeout.timeout(15) do
    until reply
      reply = transport.poll.first
      sleep(0.005) unless reply
    end
  end
  raise reply.inspect unless reply['ok'] && reply['native_instances'] == 1 && reply['changed'] == 1
  snapshot = reply
  # Repaint: no mesh buffers should cross the socket, but the worker must retain
  # the existing triangle and apply the new material record.
  transport.send({'op'=>'snapshot', 'scene'=>{'objects'=>[object],
    'materials'=>[{'id'=>'paint','color'=>'#2288FF'}]}})
  reply = nil
  Timeout.timeout(15) do
    until reply
      reply = transport.poll.first
      sleep(0.005) unless reply
    end
  end
  raise reply.inspect unless reply['ok'] && reply['native_instances'] == 1 && reply['materials_changed'] == 1
  raise 'Repaint must omit mesh buffers' unless reply['transport']['request_bytes'] < snapshot['transport']['request_bytes']
  repaint = reply
  transport.send({'op'=>'snapshot','scene'=>{'objects'=>[]}})
  reply = nil
  Timeout.timeout(15) do
    until reply
      reply = transport.poll.first
      sleep(0.005) unless reply
    end
  end
  raise reply.inspect unless reply['ok'] && reply['native_instances'] == 0 && reply['removed'] == 1
  transport.send({'op'=>'snapshot', 'scene'=>{'objects'=>[object]}})
  reply = nil
  Timeout.timeout(15) do
    until reply
      reply = transport.poll.first
      sleep(0.005) unless reply
    end
  end
  raise reply.inspect unless reply['ok'] && reply['native_instances'] == 1 && reply['changed'] == 1
  destination = File.join(folder, 'binary-transport.d5a')
  transport.send({'op' => 'export', 'path' => destination})
  reply = nil
  Timeout.timeout(15) do
    until reply
      reply = transport.poll.first
      sleep(0.005) unless reply
    end
  end
  raise reply.inspect unless reply['ok'] && reply['export_success'] && File.size(destination) > 0
  record = {:pass => true, :pid => transport.pid, :info => info, :snapshot => snapshot, :repaint=>repaint,
            :export => reply, :folder => transport.folder}
  File.write(File.join(folder, 'transport-acceptance.json'), JSON.pretty_generate(record))
  puts JSON.generate(record)
ensure
  transport.stop
  sleep(2)
end
