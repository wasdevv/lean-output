# frozen_string_literal: true

RSpec.describe LeanOutput::Scoreboard do
  def record(id, calls:, before:, after:, hits: 0, hit_bytes: 0)
    session = LeanOutput::Session.load('session_id' => id)
    session.data['gain'] = { 'calls' => calls, 'before' => before, 'after' => after,
                             'hits' => hits, 'hit_bytes' => hit_bytes }
    session.save
  end

  it 'admits it has nothing to report before the first tool call' do
    expect(described_class.render).to include('nothing measured yet')
  end

  it 'reports the saving as bytes, a percentage and an order of magnitude in tokens' do
    record('only', calls: 12, before: 100_000, after: 25_000)

    expect(described_class.render).to include('12 results', '97.7kB', '24.4kB', '-75%', '18.8k tokens')
  end

  it 'names how much of the win came from bytes the context already held' do
    record('only', calls: 4, before: 40_000, after: 10_000, hits: 3, hit_bytes: 28_000)

    expect(described_class.render).to include('3 already in context', '27.3kB')
  end

  it 'stays quiet about the ledger when nothing was deduplicated' do
    record('only', calls: 4, before: 40_000, after: 10_000)

    expect(described_class.render).not_to include('already in context')
  end

  it 'adds a machine-wide line once there is more than one session to add up' do
    record('one', calls: 1, before: 1_000, after: 500)
    record('two', calls: 1, before: 3_000, after: 500)

    rendered = described_class.render
    expect(rendered).to include('this session', 'all sessions')
    expect(rendered).to include('2 results', '3.9kB')
  end

  it 'prefers the session belonging to the directory it was asked about' do
    record('cwd-loud', calls: 99, before: 1_000, after: 500)
    quiet = LeanOutput::Session.identify('cwd' => '/tmp/quiet')
    record(quiet, calls: 7, before: 1_000, after: 500)

    expect(described_class.render('/tmp/quiet')).to include('7 results')
  end

  it 'ignores a session file it cannot parse' do
    File.write(LeanOutput::Session.path('broken'), 'not json {')
    record('good', calls: 2, before: 1_000, after: 500)

    expect(described_class.render).to include('2 results')
  end

  # The meter read 40.5% against 18.6% on a real cache where exact-command
  # matching over the same transcripts said 1.5% against 0.3%. Two causes, and
  # each one alone is enough to make the number unreadable.
  describe 'the re-run meter' do
    def session(id = 'rerun')
      LeanOutput::Session.load({ 'session_id' => id })
    end

    # `Ledger.label` shortens a Bash command to 80 characters, so a family of
    # long commands that differ at the end was one command to this counter.
    it 'tells apart two commands that share a long prefix' do
      subject = session
      prefix = 'cd /home/was/projetos/lean-output && env -u BUNDLE_GEMFILE -u BUNDLE_LOCKFILE ruby'
      subject.advance(1)
      subject.observe("`#{prefix} one.rb`", rewritten: true)
      subject.advance(1)
      subject.observe("`#{prefix} two.rb`", rewritten: true)

      expect(subject.data.dig('gain', 'reruns')).to be_zero
    end

    it 'still counts the same command run twice' do
      subject = session('same')
      2.times do
        subject.advance(1)
        subject.observe('`bundle exec rspec`', rewritten: true)
      end

      expect(subject.data.dig('gain', 'reruns')).to eq(1)
    end

    # The control used to be `calls - rewrites`, which counts every Read and
    # every tiny result the hook ever saw — things with no notion of being
    # re-run. Both sides now count what entered the watch list.
    it 'counts both rates over the results it actually watched' do
      subject = session('pair')
      subject.advance(1)
      subject.observe('`a`', rewritten: true)
      subject.advance(1)
      subject.observe('`b`', rewritten: false)
      subject.credit(10_000, 10_000)

      gain = subject.data['gain']

      expect(gain['watch_rewritten']).to eq(1)
      expect(gain['watch_plain']).to eq(1)
    end
  end
end
