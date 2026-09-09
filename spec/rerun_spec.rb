# frozen_string_literal: true

require 'spec_helper'

# The meter, deliberately without the thermostat — and stratified, which is the
# only reason its numbers mean anything.
#
# Re-running a command within three tool calls is background behaviour. Pooled
# over a real corpus the arms read 53.2% after a compressed result against 30.4%
# after a passthrough, and all twenty-three points are confounding: the
# rewritten arm is test and lint runners, which an edit-test loop re-runs
# regardless. Compared inside a command family — 35 of them seen in both arms —
# it is 40.5% against 41.2%, z = -0.49. So a cell is per family and only
# families with both arms are ever summed.
RSpec.describe 'the re-run meter' do
  def session(id = 'rerun-spec')
    LeanOutput::Session.new(id, LeanOutput::Session.blank)
  end

  # [label, family, rewritten] — two keys because they answer different
  # questions: the look-back matches the exact label, the cell is per family.
  def observe(session, calls)
    calls.each do |label, family, rewritten|
      session.advance(100)
      session.observe(label, family, rewritten: rewritten)
    end
  end

  def cells(session)
    session.data['meter']
  end

  it 'counts a re-run against the arm the earlier call belonged to' do
    subject = session
    observe(subject, [['`rspec`', 'bundle exec', true], ['`rspec`', 'bundle exec', false],
                      ['`ls`', 'ls', false], ['`ls`', 'ls', false]])

    expect(cells(subject)['bundle exec']).to eq([1, 1, 1, 0])
    expect(cells(subject)['ls']).to eq([0, 0, 2, 1])
  end

  it 'forgets a call older than the window rather than counting it' do
    subject = session
    observe(subject, [['`rspec`', 'bundle exec', true], ['`a`', 'a', false], ['`b`', 'b', false],
                      ['`c`', 'c', false], ['`rspec`', 'bundle exec', false]])

    expect(cells(subject)['bundle exec']).to eq([1, 0, 1, 0])
  end

  it 'counts every rewrite so the rate has a denominator' do
    subject = session
    observe(subject, [['`a`', 'a', true], ['`b`', 'b', false], ['`c`', 'c', true]])

    expect(subject.gain['rewrites']).to eq(2)
  end

  # The signal is "the model asked for precisely what it just got", so two
  # different greps are not a re-run of each other even though the meter
  # controls for them as one family.
  it 'matches the look-back on the exact call, not on the family' do
    subject = session
    observe(subject, [['`grep foo`', 'grep', true], ['`grep bar`', 'grep', false]])

    expect(cells(subject)['grep']).to eq([1, 0, 1, 0])
  end

  describe 'the stratification' do
    it 'offers only families that have a sample in both arms' do
      subject = session
      observe(subject, [['`a`', 'rewritten only', true], ['`a`', 'rewritten only', true],
                        ['`b`', 'passthrough only', false], ['`c`', 'both', true],
                        ['`d`', 'both', false]])

      expect(subject.strata).to eq([[1, 0, 1, 0]])
    end

    it 'keeps the file bounded without dropping the families carrying the sample' do
      subject = session
      observe(subject, [['`hot`', 'hot', true], ['`hot`', 'hot', false]])
      observe(subject, (1..80).map { |i| ["`one-off #{i}`", "one-off #{i}", false] })

      expect(cells(subject).size).to be <= LeanOutput::Session::MAX_METER
      expect(cells(subject)['hot']).to eq([1, 1, 1, 0])
    end
  end

  it 'survives a session file written before these keys existed' do
    old = LeanOutput::Session.blank
    old.delete('meter')
    old['gain'] = { 'calls' => 4, 'before' => 90, 'after' => 40, 'hits' => 0, 'hit_bytes' => 0 }
    subject = LeanOutput::Session.new('rerun-old', old)

    expect { observe(subject, [['`a`', 'a', true], ['`a`', 'a', true]]) }.not_to raise_error
    expect(cells(subject)['a']).to eq([2, 1, 0, 0])
  end

  describe 'what it prints' do
    around do |example|
      Dir.mktmpdir('rerun-scoreboard') do |dir|
        previous = ENV.fetch('LEAN_OUTPUT_STATE_DIR', nil)
        ENV['LEAN_OUTPUT_STATE_DIR'] = dir
        example.run
        ENV['LEAN_OUTPUT_STATE_DIR'] = previous
      end
    end

    it 'says nothing while no family has been seen in both arms' do
      subject = session('only-rewrites')
      subject.credit(100, 50)
      observe(subject, [['`a`', 'a', true]])
      subject.save

      expect(LeanOutput::Scoreboard.render).not_to include('re-run rate')
    end

    # A rate on its own reads like a harm figure. Beside its control it reads
    # like what it is, and beside the number of families compared a reader can
    # tell a measurement from two data points.
    it 'prints both arms and the sample once a family has both' do
      subject = session('both-arms')
      4.times { subject.credit(100, 50) }
      observe(subject, [['`a`', 'shared', true], ['`a`', 'shared', true],
                        ['`b`', 'shared', false], ['`b`', 'shared', false]])
      subject.save

      rendered = LeanOutput::Scoreboard.render

      expect(rendered).to include('after a rewrite')
      expect(rendered).to include('after a passthrough')
      expect(rendered).to include('1 command family')
    end

    # A family rewritten in one session and passed through in another is a
    # comparison the pair can make and neither can alone.
    it 'merges cells across sessions before deciding a family has both arms' do
      one = session('arm-one')
      one.credit(100, 50)
      observe(one, [['`a`', 'shared', true]])
      one.save
      two = session('arm-two')
      two.credit(100, 90)
      observe(two, [['`b`', 'shared', false]])
      two.save

      expect(LeanOutput::Scoreboard.render).to include('1 command family')
    end
  end
end
