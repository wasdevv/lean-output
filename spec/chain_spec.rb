# frozen_string_literal: true

# One shell line, several tools, one buffer. What a chain needs is not a way to
# pick a winner but a way to let each tool rewrite the part it wrote — and to
# leave untouched everything no tool claims.
RSpec.describe 'chained commands' do
  let(:rspec_output) { fixture('rspec_failures.txt') }
  let(:rubocop_output) { fixture('rubocop_offenses.txt') }
  let(:brakeman_output) { fixture('brakeman_warnings.txt') }
  let(:suite) { "#{rspec_output}\n#{rubocop_output}\n#{brakeman_output}" }
  let(:command) { 'bundle exec rspec && bundle exec rubocop && bin/brakeman -q' }

  def compress(cmd = command, output = suite)
    LeanOutput.compress(output, command: cmd)
  end

  it 'summarises every tool in the chain' do
    expect(compress).to include('RSpec:', 'RuboCop:', 'Brakeman:')
  end

  it 'orders sections by the order the tools ran' do
    reordered = "#{brakeman_output}\n#{rspec_output}"
    result = compress('bin/brakeman -q && bundle exec rspec', reordered)
    expect(result.index('Brakeman:')).to be < result.index('RSpec:')
  end

  it 'keeps every failure location the buffer carried' do
    result = compress
    reruns = rspec_output.scan(/^rspec (\S+) #/).flatten
    expect(reruns).not_to be_empty
    reruns.each { |location| expect(result).to include(location) }
  end

  it 'keeps every rubocop offense location' do
    result = compress
    locations = rubocop_output.scan(LeanOutput::Compressors::Rubocop::OFFENSE).map { |file, loc, _| [file, loc] }
    expect(locations).not_to be_empty
    locations.each do |file, loc|
      expect(result).to include(file)
      expect(result).to include(loc)
    end
  end

  it 'saves more than any single compressor could alone' do
    result = compress
    alone = compress_with(LeanOutput::Compressors::Rspec, suite)
    expect(result.bytesize).to be < suite.bytesize
    # One compressor rewrites its own span and leaves the other two tools
    # verbatim — correct, but most of the buffer is still there.
    expect(result.bytesize).to be < alone.bytesize
  end

  it 'still compresses when one tool in the chain has nothing to rewrite' do
    # A diff with no generated files leaves GitDiff with nothing to collapse.
    # That is not a reason to give up on the rspec run next to it — the diff
    # simply survives, byte for byte, outside the span that was rewritten.
    diff = fixture('git_show_plain.txt')
    result = compress('bundle exec rspec && git diff', "#{rspec_output}\n#{diff}")
    expect(result).to include('RSpec:')
    expect(result).to include(diff)
  end

  it 'compresses a segment that names two tools' do
    expect(compress('bin/ci rspec rubocop', suite)).to include('RSpec:', 'RuboCop:')
  end

  it 'compresses when quoting hides a tool from the command' do
    expect(compress('bash -c "rspec; rubocop"', suite)).to include('RSpec:', 'RuboCop:')
  end

  it 'preserves output written by a command no compressor knows' do
    migration = "== 20260101 CreateThings: migrating ==\n-- create_table(:things)\n   -> 0.0031s\n"
    result = compress('bin/rails db:migrate && bundle exec rspec', migration + rspec_output)
    expect(result).to start_with(migration)
    expect(result).to include('RSpec:')
  end
end
