# frozen_string_literal: true

RSpec.describe LeanOutput::Session do
  describe '.identify' do
    it 'uses the session id the host supplies' do
      expect(described_class.identify('session_id' => 'abc-123')).to eq('abc-123')
    end

    it 'accepts the camelCase spelling too' do
      expect(described_class.identify('sessionId' => 'abc-123')).to eq('abc-123')
    end

    # The id becomes a filename, so anything that could climb out of the state
    # directory has to be gone before it gets there.
    it 'strips everything that is not safe in a path' do
      expect(described_class.identify('session_id' => '../../etc/passwd')).to eq('etcpasswd')
    end

    it 'falls back to the working directory when there is no session id' do
      id = described_class.identify('cwd' => '/home/was/projetos/lean-output')

      expect(id).to start_with('cwd-')
      expect(id).to eq(described_class.identify('cwd' => '/home/was/projetos/lean-output'))
      expect(id).not_to eq(described_class.identify('cwd' => '/home/was/projetos/other'))
    end

    it 'lands somewhere rather than nowhere when the payload says neither' do
      expect(described_class.identify({})).to eq('global')
    end
  end

  describe 'persistence' do
    it 'survives the process that wrote it' do
      session = described_class.load('session_id' => 'persist')
      session.advance(1_000)
      session.remember('deadbeef', 'Read a.rb', 1_000)
      session.save

      reloaded = described_class.load('session_id' => 'persist')
      expect(reloaded.seq).to eq(1)
      expect(reloaded.bytes).to eq(1_000)
      expect(reloaded.lookup('deadbeef')).to include(label: 'Read a.rb', size: 1_000)
    end

    it 'reads a corrupt file as an empty session instead of raising' do
      File.write(described_class.path('broken'), 'not json {')

      expect(described_class.load('session_id' => 'broken').seq).to eq(0)
    end

    it 'discards a file written by an incompatible version' do
      File.write(described_class.path('old'), JSON.generate('v' => 0, 'seq' => 99))

      expect(described_class.load('session_id' => 'old').seq).to eq(0)
    end

    it 'reports failure rather than raising when it cannot write' do
      session = described_class.load('session_id' => 'nowhere')
      allow(File).to receive(:write).and_raise(Errno::EACCES)

      expect(session.save).to be(false)
    end
  end

  describe 'pruning' do
    it 'keeps the file bounded by dropping the oldest entries' do
      session = described_class.load('session_id' => 'busy')
      (described_class::MAX_SEEN + 50).times do |i|
        session.advance(1)
        session.remember("digest-#{i}", "call #{i}", 1)
      end

      expect(session.data['seen'].size).to eq(described_class::MAX_SEEN)
      expect(session.lookup('digest-0')).to be_nil
      expect(session.lookup("digest-#{described_class::MAX_SEEN + 49}")).not_to be_nil
    end
  end

  describe 'the running total' do
    it 'counts a passthrough as a call that saved nothing' do
      session = described_class.load('session_id' => 'gain')
      session.credit(1_000, 1_000)

      expect(session.gain).to include('calls' => 1, 'before' => 1_000, 'after' => 1_000, 'hits' => 0)
    end

    it 'separates what the ledger withheld from what a compressor rewrote' do
      session = described_class.load('session_id' => 'gain')
      session.credit(1_000, 200, hit: true)
      session.credit(1_000, 400)

      expect(session.gain).to include('calls' => 2, 'hits' => 1, 'hit_bytes' => 800)
    end
  end
end
