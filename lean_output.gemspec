# frozen_string_literal: true

require_relative 'lib/lean_output'

Gem::Specification.new do |spec|
  spec.name = 'lean_output'
  spec.version = LeanOutput::VERSION
  spec.authors = ['wasdevv']
  spec.email = ['o.u.f.acrazzy@gmail.com']

  spec.summary = 'Compress RSpec, RuboCop, Brakeman, git diff and cargo output, keeping every failure and file:line.'
  spec.description = 'Ships as a Claude Code plugin and as a library: LeanOutput.compress fits tool output ' \
                     'into a byte budget by dropping whole entries instead of truncating through a failure.'
  spec.homepage = 'https://github.com/wasdevv/lean-output'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb'] + %w[LICENSE README.md]
  spec.bindir = 'bin'
  spec.executables = ['lean-output']
  spec.require_paths = ['lib']
end
