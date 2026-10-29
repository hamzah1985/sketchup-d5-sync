# SPDX-License-Identifier: GPL-3.0-or-later
require 'sketchup.rb'
require 'extensions.rb'

module BogdanD5Sync
  VERSION = '0.1.0'.freeze
  BUILD = 1
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new('D5 Sync for SketchUp (Experimental)', 'bogdan_d5_sync/main')
    extension.description = 'Experimental geometry and camera sync to D5 Render by Bogdan Demchenko.'
    extension.version = VERSION
    extension.creator = 'Bogdan Demchenko'
    extension.copyright = '2026 Bogdan Demchenko'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
