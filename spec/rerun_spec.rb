# frozen_string_literal: true

require 'spec_helper'

# The meter, deliberately without the thermostat.
#
# Re-running a command within three tool calls is background behaviour: over
# 8680 real results it follows 15.0% of the results this plugin would rewrite
# and 14.9% of the ones it leaves alone. Anything that demoted a compressor on
# the first number alone would be acting on noise, so both arms are counted and
# neither is acted upon.
RSpec.describe 'the re-run meter' do
  def session(id = 'rerun-spec')
    LeanOutput::Session.new(id, LeanOutput::Session.blank)
  end

  def observe(session, labels)
    labels.each do |label, rewritten|
      session.advance(100)
      session.observe(label, rewritten: rewritten)
    end
  end

  it 'counts a re-run against the arm the earlier call belonged to' do
    subject = session
    observe(subject, [['`rspec`', true], ['`rspec`', false], ['`ls`', false], ['`ls`', false]])

    expect(subject.gain['reruns']).to eq(1)
    expect(subject.gain['reruns_base']).to eq(1)
  end

  it 'forgets a call older than the window rather than counting it' do
    subject = session
    observe(subject, [['`rspec`', true], ['`a`', false], ['`b`', false], ['`c`', false], ['`rspec`', false]])

    expect(subject.gain['reruns']).to be_zero
    expect(subject.gain['reruns_base']).to be_zero
  end

  it 'counts every rewrite so the rate has a denominator' do
    subject = session
    observe(subject, [['`a`', true], ['`b`', false], ['`c`', true]])

    expect(subject.gain['rewrites']).to eq(2)
  end

  it 'survives a session file written before these keys existed' do
    old = LeanOutput::Session.blank
    old['gain'] = { 'calls' => 4, 'before' => 90, 'after' => 40, 'hits' => 0, 'hit_bytes' => 0 }
    subject = LeanOutput::Session.new('rerun-old', old)

    expect { observe(subject, [['`a`', true], ['`a`', true]]) }.not_to raise_error
    expect(subject.gain['reruns']).to eq(1)
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

    it 'says nothing while one of the two arms is empty' do
      subject = session('only-rewrites')
      subject.credit(100, 50)
      observe(subject, [['`a`', true]])
      subject.save

      expect(LeanOutput::Scoreboard.render).not_to include('re-run rate')
    end

    # A rate on its own reads like a harm figure. Beside its control it reads
    # like what it is.
    it 'prints both arms once both have a sample' do
      subject = session('both-arms')
      4.times { subject.credit(100, 50) }
      observe(subject, [['`a`', true], ['`a`', true], ['`b`', false], ['`b`', false]])
      subject.save

      rendered = LeanOutput::Scoreboard.render

      expect(rendered).to include('after a rewrite')
      expect(rendered).to include('after a passthrough')
    end
  end
end
