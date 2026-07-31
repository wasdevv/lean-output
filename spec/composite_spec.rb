# frozen_string_literal: true

RSpec.describe LeanOutput::Composite do
  let(:rspec_output) { fixture('rspec_failures.txt') }
  let(:rubocop_output) { fixture('rubocop_offenses.txt') }
  let(:brakeman_output) { fixture('brakeman_warnings.txt') }
  let(:suite) { "#{rspec_output}\n#{rubocop_output}\n#{brakeman_output}" }
  let(:command) { 'bundle exec rspec && bundle exec rubocop && bin/brakeman -q' }

  def compress(cmd = command, output = suite)
    LeanOutput.compress(output, command: cmd)
  end

  it 'summarises every tool in the chain' do
    result = compress
    expect(result).to include('RSpec:', 'RuboCop:', 'Brakeman:')
  end

  it 'orders sections by the order the tools ran' do
    result = compress('bin/brakeman -q && bundle exec rspec')
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

  it 'saves more than the largest single compressor could alone' do
    result = compress
    alone = LeanOutput::Compressors::Rspec.compress(suite)
    expect(result.bytesize).to be < suite.bytesize
    # The composite reports all three tools, so it is necessarily longer than
    # the one-tool rewrite that silently dropped the other two.
    expect(result.bytesize).to be > alone.bytesize
  end

  it 'passes through when one tool in the chain has nothing to rewrite' do
    # A diff with no generated files leaves GitDiff with nothing to collapse, so
    # joining the rest would drop the whole diff without saying so.
    buffer = "#{rspec_output}\n#{fixture('git_show_plain.txt')}"
    expect(compress('bundle exec rspec && git diff', buffer)).to eq(buffer)
  end

  it 'passes through when one segment names two tools' do
    expect(compress('bin/ci rspec rubocop', suite)).to eq(suite)
  end

  it 'passes through when quoting hides a tool from the segment split' do
    expect(compress('bash -c "rspec; rubocop"', suite)).to eq(suite)
  end
end
