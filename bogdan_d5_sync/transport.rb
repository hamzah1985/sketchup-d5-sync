# SPDX-License-Identifier: GPL-3.0-or-later
require 'json'
require 'socket'
require 'thread'
require 'securerandom'
require 'fileutils'
require 'digest'
require_relative 'packet'

module BogdanD5Sync
  class Transport
    attr_reader :folder, :pid

    def self.python
      override = ENV['SKETCHUP_D5_PYTHON']
      if override && !override.empty?
        raise ArgumentError, 'SKETCHUP_D5_PYTHON does not point to a file.' unless File.file?(override)
        return File.expand_path(override)
      end
      roots = [File.join(ENV['LOCALAPPDATA'].to_s, 'Programs', 'Blender Foundation'),
               File.join(ENV['PROGRAMFILES'].to_s, 'Blender Foundation')]
      candidates = roots.map { |root| Dir.glob(File.join(File.expand_path(root), 'Blender *', '*', 'python', 'bin', 'python.exe')) }.flatten.sort.reverse
      candidates.each do |python|
        Dir.glob(File.join(File.dirname(python), 'python3*.dll')).each do |dll|
          abi = File.basename(dll)[/python(3\d+)\.dll/i, 1]
          next unless abi
          modules = Dir.glob(File.join(File.expand_path(ENV['APPDATA'].to_s), 'Blender Foundation', 'Blender', '*', 'scripts', 'addons', 'd5_export', 'tools', "d5plugin.cp#{abi}-win_amd64.pyd"))
          return python unless modules.empty?
        end
      end
      raise ArgumentError, 'Install Blender and D5 LiveSync for Blender with matching Python/NumPy, or set SKETCHUP_D5_PYTHON.'
    end

    def self.data_root
      root = ENV['LOCALAPPDATA'] || ENV['APPDATA'] || Dir.home
      File.join(root, 'BogdanD5Sync')
    end

    def initialize(model_path, live = true, legacy_identity = false, settings = {})
      @token = SecureRandom.hex(24)
      @folder = File.join(self.class.data_root, 'runs', Time.now.strftime('%Y%m%d-%H%M%S-') + @token[0,8])
      FileUtils.mkdir_p(@folder)
      identity_folder = File.join(self.class.data_root, 'models', Digest::SHA256.hexdigest(File.expand_path(model_path).downcase))
      FileUtils.mkdir_p(identity_folder)
      source = File.expand_path(model_path)
      if legacy_identity
        source = File.join(identity_folder, File.basename(model_path, File.extname(model_path)) + '.blend')
        FileUtils.cp(File.join(__dir__, 'connection.blend'), source) unless File.file?(source)
      end
      @configuration = File.join(@folder, 'worker.json')
      File.open(@configuration, 'wb') { |f| f.write(JSON.generate({'token' => @token, 'source' => source, 'connect' => live, 'd5_path' => settings['d5_path'], 'texture_folder' => settings['texture_folder']})) }
      @incoming, @outgoing = Queue.new, Queue.new
      @closed, @connected = false, false
      @receive_buffer = ''.b
      python = self.class.python
      launcher = Process.spawn('powershell.exe', '-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden',
        '-File', File.join(__dir__, 'launch_worker.ps1'), '-Python', python,
        '-Worker', File.join(__dir__, 'worker_server.py'), '-Configuration', @configuration,
        :out => File.join(@folder, 'launcher.log'), :err => [:child, :out])
      @launcher_pid = launcher
    end

    def poll
      if @launcher_pid
        begin
          @launcher_pid = nil if Process.waitpid(@launcher_pid, Process::WNOHANG)
        rescue Errno::ECHILD
          @launcher_pid = nil
        end
      end
      if @encoder
        @encoder.advance(0.003)
        if @encoder.complete?
          queue_chunks(@encoder.chunks, @encode_started, @encode_queued_at)
          @encoder = nil
        end
      end
      unless @connected || @closed
        error_file = @configuration + '.error'
        raise IOError, File.read(error_file) if File.file?(error_file)
        ready_file = File.join(@folder, 'worker.ready.json')
        if File.file?(ready_file)
          ready = JSON.parse(File.read(ready_file))
          raise IOError, 'Unexpected worker identity.' unless ready['token'] == @token
          @pid = Integer(ready['pid'])
          port = Integer(ready['port'])
          raise IOError, 'Invalid worker endpoint.' unless port > 0 && port < 65536 && @pid > 0
          @socket = TCPSocket.new('127.0.0.1', port)
          @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          @writing = [JSON.generate({'token' => @token}) + "\n"]
          @write_offset = 0
          @connected = true
        end
      end
      if @connected && !@closed
        flush
        begin
          loop do
            @receive_buffer << @socket.read_nonblock(65536)
            raise IOError, 'D5 worker response exceeds limit.' if @receive_buffer.bytesize > 4 * 1024 * 1024
            while (newline = @receive_buffer.index("\n"))
              reply = JSON.parse(@receive_buffer.slice!(0, newline + 1))
              if @request_stats
                reply['transport'] = @request_stats.merge('round_trip_ms' => (monotonic - @queued_at) * 1000.0)
              end
              @incoming << reply
            end
          end
        rescue IO::WaitReadable
          # Socket is idle. Return immediately so SketchUp can draw/respond.
        rescue EOFError
          raise IOError, 'The D5 worker closed its connection. See diagnostics.'
        end
      end
      replies = []
      replies << @incoming.pop until @incoming.empty?
      replies
    end

    def send(request)
      raise IOError, 'D5 worker is closed.' if @closed
      queued_at = monotonic
      if request['op'] == 'snapshot'
        raise IOError, 'A model update is already being packed.' if @encoder
        scene = request.fetch('scene')
        objects = scene.fetch('objects')
        current = {}
        objects.each { |object| current[object.fetch('id')] = object }
        if @sent_objects
          changed = objects.select { |object| @sent_objects[object['id']] != object }
          delta = scene.merge('objects'=>changed, 'mesh_delta'=>true,
            'removed_objects'=>@sent_objects.keys - current.keys)
          request = request.merge('scene'=>delta)
        end
        @sent_objects = current
        @encode_started = monotonic
        @encode_queued_at = queued_at
        @encoder = Packet::Encoder.new(request)
      else
        # Tiny camera/control messages stay on the GUI thread. A blocking Ruby
        # socket thread can wait a full GVL timeslice while SketchUp is drawing.
        queue_chunks(Packet.encode(request), queued_at, queued_at)
      end
      flush if @connected
    end

    def progress
      now = monotonic
      return @last_progress if @progress_at && now - @progress_at < 0.25
      @progress_at = now
      status_file = File.join(@folder, 'worker.status.json')
      @last_progress = JSON.parse(File.read(status_file))['stage'] if File.file?(status_file)
      @last_progress
    rescue Errno::EACCES, Errno::ENOENT, JSON::ParserError => error
      # Progress is advisory. A transient reader/writer lock must not disconnect
      # the authenticated model connection or discard its pending response.
      warn('D5 Sync progress read deferred: ' + error.message)
      @last_progress
    end

    def stop
      return if @closed
      @closed = true
      @encoder = nil
      @socket.close if @socket && !@socket.closed?
      # Read only this run's nonce-verified PID if launch has just completed.
      ready_file = File.join(@folder, 'worker.ready.json')
      if !@pid && File.file?(ready_file)
        ready = JSON.parse(File.read(ready_file))
        @pid = Integer(ready['pid']) if ready['token'] == @token
      end
      pid = @pid
      if pid
        UI.start_timer(1.5, false) do
          begin
            Process.kill('KILL', pid)
          rescue Errno::ESRCH => error
            # Already exited normally; this is the expected close race.
            warn("D5 Sync worker already stopped: #{error.message}")
          rescue StandardError => error
            warn("D5 Sync could not stop its worker #{pid}: #{error.message}")
          end
        end
      end
    rescue StandardError => error
      warn("D5 Sync cleanup: #{error.message}")
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def queue_chunks(chunks, started, queued_at)
      @outgoing << [chunks, {'encode_ms' => (monotonic - started) * 1000.0,
        'request_bytes' => chunks.inject(0) { |size, chunk| size + chunk.bytesize }}, queued_at] unless @closed
    end

    def flush
      # Bound each GUI visit. Mesh packing remains off-thread; camera writes are
      # a single small nonblocking operation and never wait on a thread/queue.
      budget = 1024 * 1024
      while budget > 0
        unless @writing
          break if @outgoing.empty?
          @writing, @request_stats, @queued_at = @outgoing.pop
          @write_offset = 0
        end
        chunk = @writing.first
        if chunk.nil?
          @writing = nil
          next
        end
        length = [chunk.bytesize - @write_offset, budget, 262144].min
        if length == 0
          @writing.shift
          @write_offset = 0
          next
        end
        written = @socket.write_nonblock(chunk.byteslice(@write_offset, length))
        @write_offset += written
        budget -= written
      end
    rescue IO::WaitWritable
      # Continue the exact same byte offset at the next timer tick.
    end
  end
end
