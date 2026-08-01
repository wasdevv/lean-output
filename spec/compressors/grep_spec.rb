# frozen_string_literal: true

RSpec.describe LeanOutput::Compressors::Grep do
  describe 'a recursive hit list' do
    let(:original) { fixture('grep_hits.txt') }
    subject(:compressed) { compress_with(described_class, original) }

    it 'names each file once instead of once per hit' do
      expect(original.scan('lib/lean_output.rb:').size).to be > 1
      expect(compressed.scan(%r{^lib/lean_output\.rb$}).size).to eq(1)
    end

    it 'keeps every line number' do
      original.scan(described_class::HIT) do |_, line|
        expect(compressed).to include("  #{line}:")
      end
    end

    it 'keeps every matched line verbatim' do
      original.each_line do |line|
        match = described_class::HIT.match(line) or next

        expect(compressed).to include(line[match.end(0)..])
      end
    end

    it 'keeps the hits in the order grep emitted them' do
      expect(compressed.lines.filter_map { |line| line[/^\s+(\d+):/, 1].to_i if line.match?(/^\s+\d+:/) })
        .to eq(original.scan(described_class::HIT).map { |_, line| line.to_i })
    end

    it 'declares itself lossless' do
      expect(described_class).to be_lossless
    end
  end

  describe 'output it must not touch' do
    it 'passes through when no path repeats — a header per file would grow it' do
      expect(compress_with(described_class, fixture('grep_scattered.txt'))).to be_nil
    end

    it 'passes through a log whose timestamps look like path:line' do
      log = ([
        '10:00:01 starting worker',
        '10:00:02 connected',
        '10:00:03 job 41 done',
        '10:00:04 job 42 done',
        '10:00:05 job 43 done',
        '10:00:06 shutting down'
      ].join("\n") + "\n")

      expect(compress_with(described_class, log)).to be_nil
    end

    it 'is not applicable when the command never names a grep' do
      expect(described_class).not_to be_applicable('bundle exec rspec', fixture('grep_hits.txt'))
    end

    it 'is not reachable without a command at all' do
      expect(LeanOutput::Detector.by_output(fixture('grep_hits.txt'))).not_to include(described_class)
    end
  end

  describe 'lines inside the span that are not hits' do
    it 'keeps context separators and grep notices where they were' do
      output = fixture('grep_hits.txt').lines
      spliced = (output[0, 3] + ["grep: tmp/cache: Is a directory\n", "--\n"] + output[3..]).join

      compressed = compress_with(described_class, spliced)
      expect(compressed).to include("grep: tmp/cache: Is a directory\n--\n")
    end
  end
end
