# frozen_string_literal: true

RSpec.describe 'LeanOutput.compress' do
  let(:rspec_output) { fixture('rspec_failures.txt') }
  let(:rubocop_output) { fixture('rubocop_offenses.txt') }

  it 'compresses when the command identifies the tool' do
    result = LeanOutput.compress(rspec_output, command: 'bundle exec rspec')

    expect(result.bytesize).to be < rspec_output.bytesize
    expect(result).to start_with('RSpec:')
  end

  it 'compresses from the text alone when no command is given' do
    result = LeanOutput.compress(rspec_output)

    expect(result).to start_with('RSpec:')
  end

  it 'keeps every failure location the original had' do
    reruns = rspec_output.scan(%r{rspec (\./\S+:\d+)}).flatten

    result = LeanOutput.compress(rspec_output)

    expect(reruns).not_to be_empty
    reruns.each { |location| expect(result).to include(location) }
  end

  it 'returns the input itself on passthrough' do
    text = "nothing here looks like a tool\n" * 50

    expect(LeanOutput.compress(text)).to equal(text)
  end

  it 'compresses both tools of a buffer whose command is gone' do
    both = "#{rspec_output}\n#{rubocop_output}"

    expect(LeanOutput.compress(both)).to include('RSpec:', 'RuboCop:')
  end

  it 'never claims cargo output without a command' do
    cargo = fixture('cargo_errors.txt')

    expect(LeanOutput.compress(cargo)).to equal(cargo)
    expect(LeanOutput.compress(cargo, command: 'cargo build')).not_to equal(cargo)
  end

  it 'ignores the hook line-count floor' do
    short = "1 example, 1 failure\n"

    expect(LeanOutput.compress(short, command: 'rspec')).to start_with('RSpec:')
  end

  it 'honours a budget by dropping whole failures' do
    result = LeanOutput.compress(rspec_output, command: 'bundle exec rspec', budget: 400)

    expect(result.bytesize).to be <= 400
    expect(result).to start_with('RSpec:')
    expect(result).to include('entries omitted')
  end

  it 'honours a budget on text no compressor understands' do
    text = (1..300).map { |i| "some log line #{i}" }.join("\n")

    result = LeanOutput.compress(text, budget: 500)

    expect(result.bytesize).to be <= 500
    expect(result).to include('omitted from the middle')
  end

  it 'omits the footer by default and adds it on request' do
    expect(LeanOutput.compress(rspec_output, command: 'rspec')).not_to include('[lean-output]')
    expect(LeanOutput.compress(rspec_output, command: 'rspec', footer: true)).to include('[lean-output]')
  end

  it 'adds no footer to a passthrough' do
    text = "plain text\n" * 50

    expect(LeanOutput.compress(text, footer: true)).to equal(text)
  end

  it 'degrades to the input instead of raising when a compressor blows up' do
    allow(LeanOutput::Compressors::Rspec).to receive(:summary).and_raise('boom')

    expect(LeanOutput.compress(rspec_output, command: 'rspec')).to eq(rspec_output)
  end

  it 'accepts nil' do
    expect(LeanOutput.compress(nil)).to eq('')
  end
end
