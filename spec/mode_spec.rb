# frozen_string_literal: true

RSpec.describe LeanOutput::Mode do
  around do |example|
    previous = ENV.values_at('LEAN_OUTPUT_MODE', 'LEAN_OUTPUT_DISABLE', 'LEAN_OUTPUT_CONFIG_DIR')
    example.run
    ENV['LEAN_OUTPUT_MODE'], ENV['LEAN_OUTPUT_DISABLE'], ENV['LEAN_OUTPUT_CONFIG_DIR'] = previous
  end

  describe '.resolve' do
    it 'compresses when nothing says otherwise' do
      expect(described_class.resolve('/tmp/anywhere')).to eq('full')
    end

    it 'lets the kill-switch beat every other source' do
      described_class.write('/tmp/anywhere', 'ultra')
      ENV['LEAN_OUTPUT_MODE'] = 'ultra'
      ENV['LEAN_OUTPUT_DISABLE'] = '1'

      expect(described_class.resolve('/tmp/anywhere')).to eq('off')
    end

    it 'lets an explicit env beat a flag the user forgot they set' do
      described_class.write('/tmp/anywhere', 'off')
      ENV['LEAN_OUTPUT_MODE'] = 'safe'

      expect(described_class.resolve('/tmp/anywhere')).to eq('safe')
    end

    it 'reads back the level written for that directory' do
      described_class.write('/tmp/one', 'ultra')
      described_class.write('/tmp/two', 'off')

      expect(described_class.resolve('/tmp/one')).to eq('ultra')
      expect(described_class.resolve('/tmp/two')).to eq('off')
    end

    it 'ignores a level it does not recognise' do
      expect(described_class.write('/tmp/anywhere', 'aggressive')).to be_nil
      expect(described_class.resolve('/tmp/anywhere')).to eq('full')
    end

    it 'falls back to the configured default' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'config.json'), JSON.generate('defaultMode' => 'safe'))
        ENV['LEAN_OUTPUT_CONFIG_DIR'] = dir

        expect(described_class.resolve('/tmp/anywhere')).to eq('safe')
      end
    end

    it 'survives a config file that is not JSON' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'config.json'), 'not json {')
        ENV['LEAN_OUTPUT_CONFIG_DIR'] = dir

        expect(described_class.resolve('/tmp/anywhere')).to eq('full')
      end
    end
  end

  describe '.policy' do
    it 'turns compression off entirely' do
      expect(described_class.policy('off')).to be_nil
    end

    it 'refuses anything lossy under safe' do
      expect(described_class.policy('safe')[:lossless_only]).to be(true)
    end

    it 'asks a lossy rewrite for more than a lossless one at every level that allows it' do
      %w[full ultra].each do |level|
        policy = described_class.policy(level)
        expect(policy[:ratio]).to be < policy[:lossless_ratio]
      end
    end

    it 'looks at smaller results under ultra than under full' do
      expect(described_class.policy('ultra')[:min_bytes]).to be < described_class.policy('full')[:min_bytes]
    end

    it 'describes every level it offers' do
      expect(described_class::DESCRIPTION.keys).to match_array(described_class::LEVELS)
    end
  end
end
