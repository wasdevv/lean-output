# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require_relative '../lib/lean_output'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # The ledger remembers across tool calls, so without a fresh state dir per
  # example the suite deduplicates against its own earlier examples — two specs
  # sharing a fixture, and the second one gets a reference instead of the
  # compression it was asserting on. Exported rather than stubbed because the
  # integration specs run the hook in a child process.
  # Pinned to `full` rather than left at the default, because most of this suite
  # asks what a *rung* does and the default decides which rungs are on. The
  # vault claims almost everything the compressor and ledger specs use as their
  # negative case, so an unpinned suite would assert the default over and over
  # and the rungs below it not at all. The default itself is asserted in
  # mode_spec, and volatile_spec sets its own level per example.
  config.around do |example|
    Dir.mktmpdir('lean-output-state') do |dir|
      previous = ENV.values_at('LEAN_OUTPUT_STATE_DIR', 'LEAN_OUTPUT_MODE')
      ENV['LEAN_OUTPUT_STATE_DIR'] = dir
      ENV['LEAN_OUTPUT_MODE'] ||= 'full'
      example.run
      ENV['LEAN_OUTPUT_STATE_DIR'], ENV['LEAN_OUTPUT_MODE'] = previous
    end
  end

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

def fixture(name)
  File.read(File.expand_path("fixtures/#{name}", __dir__))
end

# The host swaps the result in only when the replacement matches the tool's own
# output shape, so what an example wants to assert on is the text buried inside
# it. Unwrapping here keeps one place that knows the shapes — and the shapes
# themselves are asserted in shape_spec, against payloads copied out of a real
# transcript. That split is the whole lesson of this file: for eight versions
# every example read a String because the code wrote a String, and nothing in
# the suite ever asked the host what it accepts.
def updated_text(result)
  updated = result&.dig('hookSpecificOutput', 'updatedToolOutput')
  case updated
  when String then updated
  when Array then updated.filter_map { |block| block['text'] }.join("\n")
  when Hash then updated['stdout'] || updated.dig('file', 'content')
  end
end

# One compressor over a whole buffer, through the same path the library uses:
# find the span, summarise it, splice it back. Returns nil when the compressor
# claims nothing, which is what passthrough looks like from here.
def compress_with(compressor, output)
  plain = LeanOutput::Text.plain(output)
  rewrite = compressor.rewrite(plain) or return nil

  LeanOutput::Splice.apply(plain, [rewrite])
end
