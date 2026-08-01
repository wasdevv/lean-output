# frozen_string_literal: true

RSpec.describe LeanOutput::Detector do
  let(:rspec_output) { fixture('rspec_failures.txt') }
  let(:rubocop_output) { fixture('rubocop_offenses.txt') }

  it 'picks the RSpec compressor for an rspec command with rspec output' do
    expect(described_class.for('bundle exec rspec spec/models', rspec_output))
      .to eq([LeanOutput::Compressors::Rspec])
  end

  it 'picks the RuboCop compressor for a rubocop command with rubocop output' do
    expect(described_class.for('bundle exec rubocop app/', rubocop_output))
      .to eq([LeanOutput::Compressors::Rubocop])
  end

  it 'picks the Brakeman compressor for a brakeman command with brakeman output' do
    expect(described_class.for('bundle exec brakeman', fixture('brakeman_warnings.txt')))
      .to eq([LeanOutput::Compressors::Brakeman])
  end

  it 'picks nothing when the command matches but the output does not' do
    expect(described_class.for('bundle exec rspec', 'LoadError: cannot load such file')).to be_empty
  end

  it 'picks nothing when the output matches but the command does not' do
    expect(described_class.for('cat log/test.log', rspec_output)).to be_empty
  end

  it 'picks nothing when the user already asked for JSON format' do
    expect(described_class.for('rspec --format json spec/', rspec_output)).to be_empty
    expect(described_class.for('rubocop -f json app/', rubocop_output)).to be_empty
  end

  it 'picks both tools of a chain, in the order they are declared' do
    chained = 'bundle exec rspec && bundle exec rubocop'
    both = "#{rspec_output}\n#{rubocop_output}"
    expect(described_class.for(chained, both))
      .to eq([LeanOutput::Compressors::Rspec, LeanOutput::Compressors::Rubocop])
  end

  it 'picks both tools even when a single segment names them, since spans decide' do
    both = "#{rspec_output}\n#{rubocop_output}"
    expect(described_class.for('bin/ci rspec rubocop', both))
      .to eq([LeanOutput::Compressors::Rspec, LeanOutput::Compressors::Rubocop])
  end

  it 'picks both tools from the output alone when the command is gone' do
    both = "#{rspec_output}\n#{rubocop_output}"
    expect(described_class.by_output(both))
      .to eq([LeanOutput::Compressors::Rspec, LeanOutput::Compressors::Rubocop])
  end

  it 'handles ANSI-colored output' do
    plain = LeanOutput::Text.plain(fixture('rspec_failures_ansi.txt'))
    expect(described_class.for('bin/rspec', plain)).to eq([LeanOutput::Compressors::Rspec])
  end

  it 'picks the Cargo compressor for a cargo build command with error output' do
    expect(described_class.for('cargo build', fixture('cargo_errors.txt')))
      .to eq([LeanOutput::Compressors::Cargo])
  end

  it 'picks both tools of a cargo and rspec chain' do
    chained = 'cargo build && bundle exec rspec'
    both = "#{fixture('cargo_errors.txt')}\n#{fixture('rspec_failures.txt')}"
    expect(described_class.for(chained, both))
      .to eq([LeanOutput::Compressors::Rspec, LeanOutput::Compressors::Cargo])
  end
end
