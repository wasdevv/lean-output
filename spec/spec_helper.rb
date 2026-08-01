# frozen_string_literal: true

require_relative '../lib/lean_output'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

def fixture(name)
  File.read(File.expand_path("fixtures/#{name}", __dir__))
end

# One compressor over a whole buffer, through the same path the library uses:
# find the span, summarise it, splice it back. Returns nil when the compressor
# claims nothing, which is what passthrough looks like from here.
def compress_with(compressor, output)
  plain = LeanOutput::Text.plain(output)
  rewrite = compressor.rewrite(plain) or return nil

  LeanOutput::Splice.apply(plain, [rewrite])
end
