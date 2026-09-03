# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

module LeanOutput
  # The measured floor, written down where the hook can read it.
  #
  # Every threshold in Mode cites a measurement, and until now the path back
  # from the measurement to the constant was a human reading a table and
  # editing a file. That path has been walked three times and got it wrong
  # once: `Readback::POINTER` was copied from the ledger's reference size into
  # a sweep that prices the vault's spill, four times cheaper than the thing it
  # stood for, on both sides of the arithmetic that every floor rests on.
  #
  # It also goes stale silently. `SPILL_BYTES` was measured on one corpus; the
  # README's "the pointer is 93% of the bytes saved" was true at a 500B floor
  # and is 31% at 16kB; the last write-up nominated `ls` and `env` as the next
  # compressors on numbers that a re-run demoted below `cat`, `grep` and `sed`.
  # None of that was wrong when written. It was wrong three weeks later, and
  # nothing in the plugin noticed.
  #
  # So the sweep gets to write its own answer. Per working directory, next to
  # the mode flag and read the same way — a fresh process on every tool call,
  # so it cannot be held in memory.
  #
  # Only `spill` is calibrated. `cap` shares its number today but not its
  # measurement, and `min_bytes` and `ratio` are gates on rewrites that carry
  # no round trip, so the sweep says nothing about them. Calibrating a constant
  # this evidence does not cover would be the same mistake in a new coat.
  module Calibration
    # Below this the sweep is fitting noise. Measured the hard way: splitting
    # the same corpus by result shape produced an optimum-per-shape that beat
    # the global floor by 4.7%, and the row carrying most of that gain had two
    # spills in it. A floor chosen from a handful of round trips is a number
    # with a confidence interval wider than the decision.
    MIN_SPILLS = 30

    Result = Struct.new(:spill, :net, :spills, :roundtrips, :measured_at, keyword_init: true)

    # nil means "the corpus could not answer", and every caller treats that as
    # "keep the default" rather than as an error. A plugin that refuses to
    # compress because it could not calibrate would be worse than one that was
    # never calibrated at all.
    def self.measure(root: Readback::DEFAULT_ROOT)
      spills = Readback.collect(root: root)
      return nil if spills.size < MIN_SPILLS

      net, floor = Readback::FLOORS.map { |candidate| [Readback.net(spills, candidate), candidate] }.max
      return nil unless net.positive?

      kept = spills.select { |spill| spill.bytes > floor }
      Result.new(spill: floor, net: net.round, spills: kept.size, roundtrips: kept.count(&:read_back),
                 measured_at: Time.now.utc.strftime('%Y-%m-%d'))
    end

    def self.write(cwd, result)
      File.write(path(cwd), JSON.generate(result.to_h))
      result
    end

    # Same failure posture as `Mode.flag`: unreadable, absent or malformed all
    # mean the default. The one addition is the shape check — a JSON document
    # is not a Hash just because it parsed, and a floor of `null` reaching the
    # policy would turn every size comparison into an exception inside a hook.
    def self.read(cwd)
      parsed = JSON.parse(File.read(path(cwd)))
      return nil unless parsed.is_a?(Hash)

      floor = parsed['spill']
      floor.is_a?(Integer) && floor.positive? ? parsed : nil
    rescue StandardError
      nil
    end

    # The receipt. A calibrated floor with no date and no `n` behind it is a
    # number nobody can audit later, which is how the last one went stale
    # without anyone noticing.
    def self.describe(cwd)
      measured = read(cwd) or return nil

      format('spill floor %s — measured %s over %d spills, %d read back',
             Text.human(measured['spill']), measured['measured_at'],
             measured['spills'].to_i, measured['roundtrips'].to_i)
    end

    def self.clear(cwd)
      File.delete(path(cwd))
      true
    rescue StandardError
      false
    end

    def self.path(cwd)
      key = Digest::SHA256.hexdigest(cwd.to_s)[0, 16]
      File.join(Session.dir, "calibration-#{key}.json")
    end
  end
end
