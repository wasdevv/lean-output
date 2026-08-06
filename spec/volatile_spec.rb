# frozen_string_literal: true

require 'spec_helper'

# The only rung that removes content it cannot argue was redundant.
#
# It exists because of the shape of the corpus, not the shape of the code: over
# 8694 real results the largest 10% of calls hold 50.1% of the bytes. A
# compressor works the median result and wins a fraction of 1261B; a ceiling
# works the tail, where the bytes are. 4000B clips 6% of calls for -18.3%.
RSpec.describe 'the volatile ceiling' do
  def run(command, output, level: 'volatile')
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

  it 'leaves a result that already fits alone' do
    expect(run('echo hi', "small\n" * 3)).to be_nil
  end

  it 'brings a result over the ceiling under it' do
    expect(run('cat big.log', long).bytesize).to be <= LeanOutput::Mode::CAP_BYTES + 300
  end

  # The ends carry the subject and the verdict; the middle is what repeats.
  it 'keeps both ends and drops the middle' do
    clipped = run('cat big.log', long)

    expect(clipped).to include('line 1 of something')
    expect(clipped).to include('line 4000 of something')
    expect(clipped).not_to include('line 2000 of something')
  end

  # The trust boundary. Every other rewrite here can defend itself as
  # redundancy removal; this one cannot, so a model that is not told it holds a
  # fragment will answer as if it read the whole thing.
  it 'says it was clipped and how to get the rest' do
    clipped = run('cat big.log', long)

    expect(clipped).to include('clipped')
    expect(clipped).to include('offset/limit')
    expect(clipped).to match(/re-run the command narrower/)
  end

  it 'caps a Read the same way it caps a Bash result' do
    ENV['LEAN_OUTPUT_MODE'] = 'volatile'
    result = LeanOutput::Runner.call(
      'session_id' => 'volatile-read', 'tool_name' => 'Read',
      'tool_input' => { 'file_path' => '/tmp/big.rb' },
      'tool_response' => { 'type' => 'text', 'file' => { 'filePath' => '/tmp/big.rb', 'content' => long } }
    )

    content = result.dig('hookSpecificOutput', 'updatedToolOutput', 'file', 'content')
    expect(content.bytesize).to be < long.bytesize
    expect(content).to include('clipped')
  end

  it 'is never reached by a session that merely got long' do
    expect(LeanOutput::Mode.policy('ultra', depth: 10_000_000)).to eq(LeanOutput::Mode::POLICY['ultra'])
    expect(LeanOutput::Mode.policy('full', depth: 10_000_000)).to eq(LeanOutput::Mode::POLICY['ultra'])
  end

  # nil is the passthrough: at `ultra` the same 190kB reaches the model whole,
  # because nothing below `volatile` has a ceiling at all.
  it 'leaves every other level without a ceiling' do
    expect(run('cat big.log', long, level: 'ultra')).to be_nil
  end
end
