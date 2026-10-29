# SPDX-License-Identifier: GPL-3.0-or-later
require 'fileutils'
require 'digest'

module BogdanD5Sync
  # Read-only exporter. Rebased world vertices and inverse-transpose normals retain
  # nested, mirrored and nonuniformly scaled component placements without edits.
  class Scene
    INCH_TO_METRE = 0.0254
    IDENTITY = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]].freeze

    def initialize(model, texture_folder)
      @model, @folder = model, texture_folder
      @objects, @materials = [], {}
      @textures = {}
    end

    def self.companion(path)
      raise ArgumentError, 'Save the SketchUp model before connecting.' if path.to_s.empty?
      full = File.expand_path(path)
      raise ArgumentError, 'A saved .skp model is required.' unless File.extname(full).downcase == '.skp' && File.file?(full)
      File.join(File.dirname(full), File.basename(full, File.extname(full)) + '_d5_textures')
    end

    def capture
      raise ThreadError, 'SketchUp capture requires the main thread.' unless Thread.current == Thread.main
      walk(@model.entities, Geom::Transformation.new, [], nil, [])
      {'objects' => @objects, 'materials' => @materials.values,
       'document_path' => File.expand_path(@model.path), 'texture_folder' => @folder}
    end

    def capture_context(previous)
      raise ThreadError, 'SketchUp capture requires the main thread.' unless Thread.current == Thread.main
      active = @model.active_path
      return capture unless active && !active.empty?
      definition = active.last.definition
      prefixes = []
      visit = nil
      visit = proc do |entities, transform, ids, inherited, path|
        entities.each do |entity|
          next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          next unless visible?(entity, path)
          next_ids = ids + [entity.persistent_id.to_s]
          next_transform = transform * entity.transformation
          paint = entity.material || inherited
          next_path = path + [entity]
          if entity.definition == definition
            prefixes << next_ids.join('/') + '/'
            walk(entity.definition.entities, next_transform, next_ids, paint, next_path)
          else
            visit.call(entity.definition.entities, next_transform, next_ids, paint, next_path)
          end
        end
      end
      visit.call(@model.entities, Geom::Transformation.new, [], nil, [])
      retained = previous['objects'].reject { |object| prefixes.any? { |prefix| object['id'].start_with?(prefix) } }
      objects = retained + @objects
      used = {}
      objects.each { |object| used[object['material_id']] = true }
      # Material editor changes can affect surfaces outside the active context.
      # Refresh material records without triangulating those other objects.
      @model.materials.each do |material|
        material_key(material) if used['material-' + material.entityID.to_s]
      end
      {'objects'=>objects, 'materials'=>@materials.values.select { |material| used[material['id']] },
       'document_path'=>File.expand_path(@model.path), 'texture_folder'=>@folder}
    end

    def self.camera(view)
      cam = view.camera
      aspect = cam.aspect_ratio.to_f
      aspect = view.vpwidth.to_f / [view.vpheight, 1].max if aspect <= 0
      fov = cam.perspective? ? cam.fov.to_f : 60.0
      if cam.perspective? && cam.fov_is_height?
        fov = 2.0 * Math.atan(Math.tan(fov * Math::PI / 360.0) * aspect) * 180.0 / Math::PI
      end
      {'position' => cam.eye.to_a.map { |n| n.to_f * INCH_TO_METRE },
       'forward' => cam.direction.to_a, 'up' => cam.up.to_a,
       'horizontal_fov' => [[fov, 1.0].max, 179.0].min,
       'orthographic' => !cam.perspective?,
       'orthographic_width' => cam.perspective? ? 10.0 : cam.height.to_f * INCH_TO_METRE * aspect}
    end

    private

    def visible?(entity, path)
      return false if entity.hidden? || !entity.layer.visible?
      @model.drawing_element_visible?(path + [entity])
    end

    def walk(entities, transform, ids, inherited, path)
      buckets = {}
      entities.each do |entity|
        next unless entity.is_a?(Sketchup::Drawingelement) && visible?(entity, path)
        if entity.is_a?(Sketchup::Face)
          material = entity.material || inherited
          mid = material_key(material)
          bucket = buckets[mid] ||= {'id' => (ids + [mid]).join('/'),
            'name' => ids.empty? ? 'Model geometry' : 'Component geometry',
            'vertices' => [], 'normals' => [], 'triangles' => [], 'uvs' => [],
            'material_id' => mid, 'transform' => IDENTITY}
          append_face(bucket, entity, transform, material)
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          walk(entity.definition.entities, transform * entity.transformation,
               ids + [entity.persistent_id.to_s], entity.material || inherited, path + [entity])
        end
      end
      buckets.values.each do |object|
        next if object['triangles'].empty?
        # Keep float32 mesh coordinates near zero. Placement stays in a separate
        # translation so a distant component's small faces do not collapse.
        origin = object['vertices'].first.dup
        object['vertices'].each { |point| 3.times { |axis| point[axis] -= origin[axis] } }
        object['transform'] = [[1,0,0,origin[0]],[0,1,0,origin[1]],
                               [0,0,1,origin[2]],[0,0,0,1]]
        @objects << object
      end
    end

    def material_key(material)
      return '__default__' unless material
      key = 'material-' + material.entityID.to_s
      return key if @materials.key?(key)
      color = material.color
      record = {'id' => key, 'name' => material.display_name,
        'color' => format('#%02X%02X%02X', color.red, color.green, color.blue),
        'roughness' => 0.5, 'metallic' => 0.0, 'alpha' => material.alpha.to_f}
      if material.texture
        # Export embedded textures too; no dependency on the original pathname.
        image = material.texture.image_rep(true)
        digest = Digest::SHA256.hexdigest([image.width, image.height].pack('L<2') + image.data)
        filename = File.join(@folder, digest + '.png')
        unless File.file?(filename)
          raise IOError, 'Could not write the companion texture.' unless material.texture.write(filename, true)
        end
        record['diffuse_map'] = filename
        record['color'] = '#FFFFFF'
      end
      @materials[key] = record
      key
    end

    def append_face(bucket, face, transform, material)
      mesh = face.mesh(5)
      inverse = transform.inverse.to_a
      mirrored = transform.xaxis.cross(transform.yaxis).dot(transform.zaxis) < 0
      offset = bucket['vertices'].length
      helper = face.get_UVHelper(true, false) if material && material.texture && face.material
      points = mesh.points
      points.each_with_index do |point, index|
        bucket['vertices'] << point.transform(transform).to_a.map { |n| n.to_f * INCH_TO_METRE }
        normal = mesh.normal_at(index + 1) || face.normal
        nx, ny, nz = normal.to_a
        result = [inverse[0]*nx + inverse[1]*ny + inverse[2]*nz,
                  inverse[4]*nx + inverse[5]*ny + inverse[6]*nz,
                  inverse[8]*nx + inverse[9]*ny + inverse[10]*nz]
        length = Math.sqrt(result.inject(0.0) { |sum, n| sum + n*n })
        raise ArgumentError, 'A face has a zero normal.' if length < 1.0e-12
        bucket['normals'] << result.map { |n| n / length }
        if helper
          uvq = helper.get_front_UVQ(point)
          q = uvq.z.abs > 1.0e-12 ? uvq.z : 1.0
          # SketchUp UVQ is bottom-up. The bridge's texture convention is
          # top-down; convert here, including projective Q, once per corner.
          bucket['uvs'] << [uvq.x / q, 1.0 - uvq.y / q]
        elsif material && material.texture
          # Simple local projection for inherited container textures.
          xaxis, yaxis = face.normal.axes
          bucket['uvs'] << [point.to_a.zip(xaxis.to_a).inject(0.0) { |s, pair| s + pair[0]*pair[1] } / material.texture.width.to_f,
                            1.0 - point.to_a.zip(yaxis.to_a).inject(0.0) { |s, pair| s + pair[0]*pair[1] } / material.texture.height.to_f]
        else
          bucket['uvs'] << [0.0, 0.0]
        end
      end
      mesh.polygons.each do |polygon|
        indices = polygon.map { |i| offset + i.abs - 1 }
        (1...(indices.length - 1)).each do |i|
          triangle = [indices[0], indices[i], indices[i+1]]
          triangle.reverse! if mirrored
          bucket['triangles'] << triangle
        end
      end
    end
  end
end
