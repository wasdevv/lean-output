# frozen_string_literal: true

require_relative 'lean_output/text'
require_relative 'lean_output/compressors/rspec'
require_relative 'lean_output/compressors/rubocop'
require_relative 'lean_output/compressors/brakeman'
require_relative 'lean_output/compressors/git_diff'
require_relative 'lean_output/detector'
require_relative 'lean_output/runner'

module LeanOutput
  VERSION = '0.3.0'
end
