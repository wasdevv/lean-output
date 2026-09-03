# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The rungs that keep state from growing forever, and the two gates that were
# loose enough to act on the wrong thing.
RSpec.describe 'housekeeping' do
  around do |example|
    Dir.mktmpdir('housekeeping') do |dir|
      previous = ENV.fetch('LEAN_OUTPUT_STATE_DIR', nil)
      ENV['LEAN_OUTPUT_STATE_DIR'] = dir
      example.run(@dir = dir)
      ENV['LEAN_OUTPUT_STATE_DIR'] = previous
    end
  end

  describe LeanOutput::Session do
    def session(id)
      described_class.load({ 'session_id' => id })
    end

    # Measured on a real cache before this existed: 53 session files going back
    # four weeks. A session id never comes back, so the moment its host process
    # ends the file is dead weight nothing will read again.
    it 'drops session state that has gone past the keep window' do
      session('old').save
      stale = described_class.path('old')
      moment = Time.now.utc - ((described_class::KEEP_DAYS + 1) * 86_400)
      File.utime(moment, moment, stale)

      session('fresh').save

      expect(File.exist?(stale)).to be(false)
      expect(File.exist?(described_class.path('fresh'))).to be(true)
    end

    it 'keeps state that is merely idle' do
      session('yesterday').save
      moment = Time.now.utc - 86_400
      File.utime(moment, moment, described_class.path('yesterday'))

      session('fresh').save

      expect(File.exist?(described_class.path('yesterday'))).to be(true)
    end
  end

  describe LeanOutput::Detector do
    let(:failures) { File.read('spec/fixtures/rspec_failures.txt') }

    # The flag has to be a flag and the value has to be the format. Unanchored,
    # any filename starting with `j` disabled every compressor on the buffer.
    it 'stands aside for output that really is JSON' do
      expect(described_class.for('bundle exec rspec --format json', failures)).to be_empty
      expect(described_class.for('bundle exec rspec -f j', failures)).to be_empty
    end

    # `grep -f <file>` reads patterns from a file. Unanchored, the file's name
    # was being read as a format flag's value.
    it 'no longer bails on a filename that happens to start with j' do
      hits = File.read('spec/fixtures/grep_hits.txt')

      expect(described_class.for('grep -rn -f jargon.txt app/', hits)).not_to be_empty
    end

    # `--format junit` is XML. Bailing on it left cargo output unclaimed for a
    # reason that was not true of the output.
    it 'no longer bails on a format that is not json' do
      cargo = File.read('spec/fixtures/cargo_errors.txt')

      expect(described_class.for('cargo test --format junit', cargo)).not_to be_empty
    end
  end

  describe LeanOutput::ScanCache do
    it 'returns the memo while the file is unchanged and recomputes once it moves' do
      file = File.join(@dir, 'transcript.jsonl')
      File.write(file, "one\n")
      calls = 0
      compute = -> { calls += 1 and [{ 'n' => calls }] }

      described_class.fetch('spec', file, &compute)
      described_class.fetch('spec', file, &compute)
      expect(calls).to eq(1)

      File.write(file, "one\ntwo\n")
      described_class.fetch('spec', file, &compute)
      expect(calls).to eq(2)
    end

    # Every failure mode is a miss, because a miss is the answer the caller
    # wanted anyway — only slower.
    it 'recomputes rather than raising when the memo is damaged' do
      file = File.join(@dir, 'transcript.jsonl')
      File.write(file, "one\n")
      described_class.fetch('spec', file) { [{ 'n' => 1 }] }
      Dir.glob(File.join(@dir, 'scan', '*.json')).each { |memo| File.write(memo, 'not json') }

      expect(described_class.fetch('spec', file) { [{ 'n' => 2 }] }).to eq([{ 'n' => 2 }])
    end
  end

  describe LeanOutput::Corpus do
    it 'names a tool it has no compressor for instead of ranking it as unclaimable' do
      results = [described_class::Result.new(tool: 'Bash', command: 'pytest', bytes: 9_000,
                                             saved: 0, claimed: false, shape: 'pytest')]

      expect(described_class.report(results)).to include('no compressor here', 'pytest')
    end

    it 'says nothing when the roster already covers what ran' do
      results = [described_class::Result.new(tool: 'Bash', command: 'ls', bytes: 900,
                                             saved: 0, claimed: false, shape: nil)]

      expect(described_class.report(results)).not_to include('no compressor here')
    end
  end

  describe 'the library path' do
    # The scoreboard reads session state written by the hook, so a caller using
    # the gem directly saved bytes that appeared in no total anywhere.
    it 'bills a named caller so its savings are visible to the scoreboard' do
      LeanOutput.compress(File.read('spec/fixtures/rspec_failures.txt'),
                          command: 'bundle exec rspec', credit: 'qa-gate')

      billed = LeanOutput::Session.load({ 'session_id' => 'lib-qa-gate' })

      expect(billed.data.dig('gain', 'calls')).to eq(1)
      expect(billed.data.dig('gain', 'after')).to be < billed.data.dig('gain', 'before')
    end

    it 'bills nothing when no caller asked to be billed' do
      LeanOutput.compress('short', command: 'ls')

      expect(Dir.glob(File.join(@dir, 'lib-*.json'))).to be_empty
    end
  end
end
