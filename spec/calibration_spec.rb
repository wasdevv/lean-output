# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe LeanOutput::Calibration do
  # A spill big enough to clear the floor being tested, carried for long enough
  # that withholding it is worth something. `read_back: false` is what makes a
  # pointer pay; a followed one costs a whole prefix.
  def spill(bytes:, read_back: false, remaining: 300, prefix: 0)
    LeanOutput::Readback::Spill.new(bytes: bytes, remaining: remaining,
                                    read_back: read_back, prefix: prefix, pointer: 1000)
  end

  around do |example|
    Dir.mktmpdir('calibration') do |dir|
      previous = ENV.fetch('LEAN_OUTPUT_STATE_DIR', nil)
      ENV['LEAN_OUTPUT_STATE_DIR'] = dir
      example.run(@cwd = File.join(dir, 'repo'))
      ENV['LEAN_OUTPUT_STATE_DIR'] = previous
    end
  end

  describe '.measure' do
    it 'picks the floor at the top of the sweep' do
      # Small spills that get followed are the loss the floor exists to avoid;
      # large ones nobody follows are the win it exists to keep.
      cheap = Array.new(40) { spill(bytes: 1_000, read_back: true, prefix: 200_000) }
      dear = Array.new(40) { spill(bytes: 40_000) }
      allow(LeanOutput::Readback).to receive(:collect).and_return(cheap + dear)

      expect(described_class.measure.spill).to be >= 3_000
    end

    # Fail closed, and the reason is measured: splitting one corpus by result
    # shape produced an optimum-per-shape beating the global floor by 4.7%,
    # with the row carrying most of that gain holding two spills.
    it 'refuses to answer from a corpus too small to have an answer' do
      allow(LeanOutput::Readback).to receive(:collect).and_return([spill(bytes: 40_000)])

      expect(described_class.measure).to be_nil
    end

    it 'refuses when no floor pays for itself' do
      followed = Array.new(40) { spill(bytes: 40_000, read_back: true, prefix: 900_000) }
      allow(LeanOutput::Readback).to receive(:collect).and_return(followed)

      expect(described_class.measure).to be_nil
    end
  end

  describe 'what the hook reads' do
    it 'replaces the spill floor for this directory and leaves every other key' do
      described_class.write(@cwd, described_class::Result.new(spill: 3_000, net: 1, spills: 40,
                                                              roundtrips: 2, measured_at: '2026-09-03'))

      policy = LeanOutput::Mode.policy('volatile', @cwd)

      expect(policy[:spill]).to eq(3_000)
      expect(policy[:min_bytes]).to eq(LeanOutput::Mode::POLICY.fetch('volatile')[:min_bytes])
      expect(policy[:ratio]).to eq(LeanOutput::Mode::POLICY.fetch('volatile')[:ratio])
    end

    it 'keeps the default when nothing was calibrated here' do
      expect(LeanOutput::Mode.policy('volatile', @cwd)[:spill]).to eq(LeanOutput::Mode::SPILL_BYTES)
    end

    # Same posture as the mode flag: a file that cannot be trusted is a file
    # that is not there. A `spill` of null reaching a size comparison would
    # raise inside a hook, which is the one thing this plugin never does.
    it 'ignores a calibration file that is damaged' do
      File.write(described_class.path(@cwd), '{"spill": null}')

      expect(LeanOutput::Mode.policy('volatile', @cwd)[:spill]).to eq(LeanOutput::Mode::SPILL_BYTES)
    end

    it 'carries the date and the sample size, so the number can be audited later' do
      today = Time.now.utc.strftime('%Y-%m-%d')
      described_class.write(@cwd, described_class::Result.new(spill: 3_000, net: 1, spills: 40,
                                                              roundtrips: 2, measured_at: today))

      expect(described_class.describe(@cwd)).to include(today, '40 spills', '2 read back')
      expect(described_class.describe(@cwd)).not_to include('calibrate` again')
    end

    # The failure this command exists to fix, one level down: the floor was
    # right when it was taken and nothing notices when it stops being. Asserted
    # because the age arithmetic is the kind that fails to nil quietly.
    it 'asks to be re-run once the measurement is older than the window' do
      old = Time.now.utc - ((described_class::STALE_DAYS + 5) * 86_400)
      described_class.write(@cwd, described_class::Result.new(spill: 3_000, net: 1, spills: 40, roundtrips: 2,
                                                              measured_at: old.strftime('%Y-%m-%d')))

      expect(described_class.describe(@cwd)).to include('35 days ago', 'run `lean calibrate` again')
    end
  end
end
