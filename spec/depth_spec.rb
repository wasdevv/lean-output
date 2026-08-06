# frozen_string_literal: true

require 'spec_helper'

# The level climbs one step once a session is deep enough that the next result
# is plausibly pushing something out — and only ever climbs. The symmetric
# version (gentle early, harder later) is the one the corpus rejected: 55% of
# tool-output bytes arrive while a session is still under 100kB deep.
RSpec.describe 'the level follows how deep the session already is' do
  it 'leaves a shallow session at the level it defaulted to' do
    expect(LeanOutput::Mode.policy('full', depth: 0)).to eq(LeanOutput::Mode::POLICY['full'])
    expect(LeanOutput::Mode.policy('full', depth: 249_999)).to eq(LeanOutput::Mode::POLICY['full'])
  end

  it 'climbs one step past the window the ledger already measures in' do
    expect(LeanOutput::Mode.policy('full', depth: 250_000)).to eq(LeanOutput::Mode::POLICY['ultra'])
  end

  it 'stops at the top rather than running off the end of the list' do
    expect(LeanOutput::Mode.policy('ultra', depth: 5_000_000)).to eq(LeanOutput::Mode::POLICY['ultra'])
  end

  # `lean safe` is someone saying they suspect a compressor ate the line they
  # needed. A long session is not an argument against them.
  it 'never moves a level the user asked for' do
    expect(LeanOutput::Mode.policy('safe', depth: nil)).to eq(LeanOutput::Mode::POLICY['safe'])
  end

  describe 'what Runner passes as depth' do
    it 'reports a chosen level as chosen and an absent one as defaulted' do
      expect(LeanOutput::Mode.source('/nowhere-at-all')).to eq([LeanOutput::Mode::DEFAULT, :default])

      ENV['LEAN_OUTPUT_MODE'] = 'safe'
      expect(LeanOutput::Mode.source('/nowhere-at-all')).to eq(%w[safe].push(:chosen))
    ensure
      ENV.delete('LEAN_OUTPUT_MODE')
    end

    it 'counts the kill switch as a decision, not a default' do
      ENV['LEAN_OUTPUT_DISABLE'] = '1'
      expect(LeanOutput::Mode.source('/nowhere-at-all')).to eq(['off', :chosen])
    ensure
      ENV.delete('LEAN_OUTPUT_DISABLE')
    end
  end

  # End to end, through the hook, with the same bytes twice. 236B over 6 lines
  # sits under `full`'s 400B floor and over `ultra`'s 200B one, so the depth
  # step is the only thing that can change the answer.
  describe 'through the hook, with the same result at two depths' do
    let(:output) do
      (1..3).flat_map { |i| (1..2).map { |j| "app/services/thing_#{i}.rb:#{j * 7}:  def call_#{j}" } }
            .join("\n")
    end

    def run(session_id)
      LeanOutput::Runner.call(
        'hook_event_name' => 'PostToolUse', 'session_id' => session_id, 'cwd' => Dir.pwd,
        'tool_name' => 'Bash', 'tool_input' => { 'command' => 'grep -rn x app/' },
        'tool_response' => { 'stdout' => output, 'stderr' => '', 'interrupted' => false,
                             'isImage' => false, 'noOutputExpected' => false }
      )
    end

    def sink(session_id, bytes)
      session = LeanOutput::Session.new(session_id, LeanOutput::Session.blank)
      session.advance(bytes)
      session.save
    end

    it 'passes it through while the session is shallow' do
      expect(run('depth-shallow')).to be_nil
    end

    it 'rewrites it once the session is deep' do
      sink('depth-deep', LeanOutput::Mode::DEEP_BYTES)

      expect(updated_text(run('depth-deep'))).to include('app/services')
    end
  end
end
