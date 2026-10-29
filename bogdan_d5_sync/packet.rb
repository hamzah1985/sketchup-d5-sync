# SPDX-License-Identifier: GPL-3.0-or-later
require 'json'

module BogdanD5Sync
  # Numeric buffers avoid per-number JSON formatting. Incremental packing runs
  # only on the host thread; each step yields between small numeric blocks.
  module Packet
    FIELDS = {'vertices' => [3, 'e*'], 'triangles' => [3, 'l<*'],
              'normals' => [3, 'e*'], 'uvs' => [2, 'e*']}.freeze

    def self.encode(request)
      return [JSON.generate(request) + "\n"] unless request['op'] == 'snapshot'
      encoder = Encoder.new(request)
      encoder.advance(0.01) until encoder.complete?
      encoder.chunks
    end

    class Encoder
      attr_reader :chunks
      def initialize(request)
        @complete = false
        @scene = request.fetch('scene').dup
        @objects = @scene.fetch('objects')
        @metadata, @buffers = [], []
        @object_index, @field_index, @row_index = 0, 0, 0
        @fields = FIELDS.to_a
        @payload_bytes = 0
      end
      def complete?; @complete; end
      def advance(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        begin
          step unless @complete
        end while !@complete && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      end

      private

      # No Fiber or external Enumerator: allocations must stay on the calling
      # GUI execution stack, including SketchUp's native GC callbacks.
      def step
        if @object_index >= @objects.length
          @scene['objects'] = @metadata
          header = {'op'=>'snapshot', 'mesh_encoding'=>'le32-v1',
                    'payload_bytes'=>@payload_bytes, 'scene'=>@scene}
          @chunks = [JSON.generate(header) + "\n"] + @buffers
          @complete = true
          return
        end
        object = @objects[@object_index]
        @current ||= object.dup
        if @field_index >= @fields.length
          @metadata << @current
          @current = nil
          @object_index += 1
          @field_index, @row_index = 0, 0
          return
        end
        name, spec = @fields[@field_index]
        unless object.key?(name)
          @field_index += 1
          return
        end
        values = object.fetch(name)
        columns, format = spec
        @current[name] = {'rows'=>values.length, 'bytes'=>values.length * columns * 4}
        block = values[@row_index, 2048]
        unless block.empty?
          raise ArgumentError, 'Invalid mesh array: ' + name unless block.all? { |row| row.length == columns }
          buffer = block.flatten.pack(format)
          @buffers << buffer
          @payload_bytes += buffer.bytesize
        end
        @row_index += block.length
        if @row_index >= values.length
          @field_index += 1
          @row_index = 0
        end
      end
    end

    def self.build(request)
      return [JSON.generate(request) + "\n"] unless request['op'] == 'snapshot'
      chunks = []
      scene = request.fetch('scene').dup
      scene['objects'] = scene.fetch('objects').map do |object|
        metadata = object.dup
        FIELDS.each do |name, spec|
          next unless metadata.key?(name)
          values = metadata.delete(name)
          columns, format = spec
          metadata[name] = {'rows' => values.length, 'bytes' => values.length * columns * 4}
          values.each_slice(2048) do |block|
            raise ArgumentError, 'Invalid mesh array: ' + name unless block.all? { |row| row.length == columns }
            chunks << block.flatten.pack(format)
            yield if block_given?
          end
        end
        metadata
      end
      header = {'op' => 'snapshot', 'mesh_encoding' => 'le32-v1',
                'payload_bytes' => chunks.inject(0) { |size, chunk| size + chunk.bytesize }, 'scene' => scene}
      [JSON.generate(header) + "\n"] + chunks
    end
  end
end
