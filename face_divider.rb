require 'sketchup.rb'
require 'extensions.rb'

module FaceDivider
  PLUGIN_ID = 'face_divider'.freeze
  PLUGIN_NAME = 'Face Divider'.freeze
  VERSION = '1.0.0'.freeze

  unless defined?(FaceDivider::EXTENSION)
    loader = File.join(__dir__, 'face_divider', 'main')
    EXTENSION = SketchupExtension.new(PLUGIN_NAME, loader)
    EXTENSION.description = 'Tools for subdividing faces with parallel lines and rectangular grids.'
    EXTENSION.version = VERSION
    EXTENSION.creator = 'OpenAI Assistant'
    Sketchup.register_extension(EXTENSION, true)
  end
end
