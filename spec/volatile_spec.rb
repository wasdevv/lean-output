# frozen_string_literal: true

require 'spec_helper'

# `volatile` is two rungs the other levels do not have, and they answer
# different questions about the same result.
#
# The vault answers "does this have to be in the context window at all" — the
# bytes go to a file and come back as their two ends and a path, losing
# nothing. The ceiling answers "how big may a rewrite be" and is the only place
# in this plugin where content is actually discarded, so it applies to what a
# compressor already distilled and never to raw output the vault can keep.
#
# The case for both is the shape of the corpus: over 8745 real results the
# largest 10% of calls hold 50.1% of the bytes and the median is 1261B. The
# vault takes that corpus to -65%, the ceiling alone to -22%, compressors -6%.
RSpec.describe 'the volatile level' do
  def bash(command, output, level: 'volatile')
    ENV['LEAN_OUTPUT_MODE'] = level
    LeanOutput::Runner.call(
      'session_id' => "volatile-#{rand(1 << 32)}",
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => command },
      'tool_response' => { 'stdout' => output, 'stderr' => '' }
    )&.dig('hookSpecificOutput', 'updatedToolOutput', 'stdout')
  end

  around do |example|
    previous = ENV.fetch('LEAN_OUTPUT_MODE', nil)
    Dir.mktmpdir('volatile') do |dir|
      ENV['LEAN_OUTPUT_STATE_DIR'] = dir
      example.run
    end
    ENV['LEAN_OUTPUT_MODE'] = previous
  end

  let(:long) { (1..4000).map { |n| "line #{n} of something incompressible #{n * 7919}" }.join("\n") }

  def vault_path(text)
    text[/Full output: (\S+)/, 1]
  end

  describe 'the vault' do
    it 'leaves a result that is cheaper to carry than to point at' do
      expect(bash('echo hi', "small\n" * 3)).to be_nil
    end

    it 'replaces a long unclaimed result with its ends and a path' do
      pointer = bash('cat big.log', long)

      expect(pointer.bytesize).to be < 1_500
      expect(pointer).to include('line 1 of something')
      expect(pointer).to include('line 4000 of something')
      expect(pointer).not_to include('line 2000 of something')
    end

    # The whole difference between this rung and the ceiling: nothing was
    # destroyed, so the middle is a Read away rather than gone.
    it 'writes the original byte for byte where it says it did' do
      path = vault_path(bash('cat big.log', long))

      expect(File.read(path)).to eq(long)
    end

    it 'tells the model how to get the middle back' do
      pointer = bash('cat big.log', long)

      expect(pointer).to include('nothing was lost')
      expect(pointer).to match(/Read that path .* or grep it/)
    end

    it 'spills a Read the same way it spills a Bash result' do
      ENV['LEAN_OUTPUT_MODE'] = 'volatile'
      result = LeanOutput::Runner.call(
        'session_id' => 'volatile-read', 'tool_name' => 'Read',
        'tool_input' => { 'file_path' => '/tmp/big.rb' },
        'tool_response' => { 'type' => 'text',
                             'file' => { 'filePath' => '/tmp/big.rb', 'content' => long } }
      )

      content = result.dig('hookSpecificOutput', 'updatedToolOutput', 'file', 'content')
      expect(File.read(vault_path(content))).to eq(long)
    end

    # A compressed result is distilled signal. Hiding *that* behind a pointer
    # would put the failures someone is about to read one tool call further
    # away, and the bytes it replaced are already gone.
    it 'never spills what a compressor claimed' do
      rspec = File.read('spec/fixtures/rspec_failures.txt')
      pointer = bash('bundle exec rspec', rspec)

      expect(pointer).not_to include('Full output:')
      expect(pointer).to include('rspec ./')
    end

    it 'is off at every level below volatile' do
      expect(bash('cat big.log', long, level: 'ultra')).to be_nil
      expect(bash('cat big.log', long, level: 'full')).to be_nil
    end
  end

  describe 'the ceiling' do
    it 'brings a rewrite that is still enormous under the cap' do
      text = 'x' * 20_000
      clipped = LeanOutput::Text.clip(text, LeanOutput::Mode::CAP_BYTES)

      expect(clipped.bytesize).to be <= LeanOutput::Mode::CAP_BYTES + 5
    end

    it 'exists only at volatile' do
      expect(LeanOutput::Mode::POLICY['ultra'][:cap]).to be_nil
      expect(LeanOutput::Mode::POLICY['volatile'][:cap]).to eq(LeanOutput::Mode::CAP_BYTES)
    end

    # It is the only rung that can lose something, so nothing may arrive at it
    # by accident — a session that merely got long climbs to ultra and stops.
    it 'is never reached by a session that merely got long' do
      expect(LeanOutput::Mode.policy('ultra', depth: 10_000_000)).to eq(LeanOutput::Mode::POLICY['ultra'])
      expect(LeanOutput::Mode.policy('full', depth: 10_000_000)).to eq(LeanOutput::Mode::POLICY['ultra'])
    end
  end
end
