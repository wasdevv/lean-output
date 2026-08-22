# frozen_string_literal: true

require 'json'

module LeanOutput
  # Whether the model follows the pointers this plugin hands out.
  #
  # Every threshold here used to be set on delivery-side bytes alone — what a
  # rewrite withholds at the moment it is handed over. That number never asks
  # what happens next, and what happens next is that the model reads the file:
  # measured over 152 transcripts, **80% of spills are read back**, 90.6% of
  # them within one tool call, and 99.2% of those read the whole file rather
  # than a slice. Counting only the delivery side is what put the spill floor at
  # 500B, where the rung was losing on 59% of its own firings.
  #
  # A followed pointer costs the pointer *plus* the bytes *plus* a turn, and a
  # turn re-reads the whole accumulated prefix. So this measures three things
  # the corpus report cannot see: how often a pointer is the last word, how many
  # turns each result would still have been carried for, and how large the
  # prefix was when the model went back for it.
  #
  # It exists as a command rather than a script in someone's scratch directory
  # because every future threshold has the same question behind it, and the
  # answer moves when the plugin's own behaviour moves.
  module Readback
    DEFAULT_ROOT = '~/.claude/projects'
    POINTER = 280
    UNIT = { 'B' => 1, 'kB' => 1024, 'MB' => 1_048_576 }.freeze
    # Both shapes the vault writes: the full notice, and the terse one it uses
    # once the explanation is already in the window. The dash is the only
    # difference and it is optional here on purpose — a matcher that knew one
    # shape would drop every spill after the first per window, silently, and
    # report a read-back rate computed from a fraction of the pointers.
    NOTICE = /withheld (?:— )?([\d.]+)(B|kB|MB), \d+ lines, full text at (\S+)/
    VAULT = 'lean-output/vault'

    Spill = Struct.new(:bytes, :remaining, :read_back, :prefix, keyword_init: true)

    def self.collect(root: DEFAULT_ROOT)
      Dir.glob(File.join(File.expand_path(root), '*', '*.jsonl')).flat_map { |file| from_session(file) }
    end

    # One session at a time, in order, because "how many turns are left" and
    # "how big was the prefix" are only answerable against the session's own
    # timeline.
    def self.from_session(file)
      turn = 0
      prefix = []
      spills = {}
      reads = {}

      File.foreach(file) do |line|
        record = parse(line) or next
        turn += 1 if (read = cache_read(record))
        prefix[turn] = read if read
        scan(record, turn, spills, reads)
      end

      spills.map do |path, (at, bytes)|
        back = reads[path]
        Spill.new(bytes: bytes, remaining: [turn - at, 0].max,
                  read_back: !back.nil?, prefix: back ? (prefix[back] || typical(prefix)) : 0)
      end
    end
    private_class_method :from_session

    def self.cache_read(record)
      value = record.dig('message', 'usage', 'cache_read_input_tokens').to_i
      value.positive? ? value : nil
    end
    private_class_method :cache_read

    def self.scan(record, turn, spills, reads)
      blocks = record.dig('message', 'content')
      return unless blocks.is_a?(Array)

      blocks.each do |block|
        next unless block.is_a?(Hash)

        case block['type']
        when 'tool_use' then note_read(block, turn, reads)
        when 'tool_result' then note_spills(block, turn, spills)
        end
      end
    end
    private_class_method :scan

    def self.note_read(block, turn, reads)
      return unless block['name'] == 'Read'

      path = block.dig('input', 'file_path').to_s
      reads[path] ||= turn if path.include?(VAULT)
    end
    private_class_method :note_read

    def self.note_spills(block, turn, spills)
      text(block).scan(NOTICE) do |size, unit, path|
        spills[path] = [turn, (size.to_f * UNIT[unit]).round]
      end
    end
    private_class_method :note_spills

    def self.text(block)
      content = block['content']
      return content.to_s if content.is_a?(String)

      Array(content).filter_map { |part| part['text'] if part.is_a?(Hash) }.join("\n")
    end
    private_class_method :text

    # A read-back whose own turn has no usage line still happened; the session's
    # own average is a better stand-in than zero, which would price it free.
    def self.typical(prefix)
      seen = prefix.compact
      seen.empty? ? 0 : seen.sum / seen.size
    end
    private_class_method :typical

    def self.parse(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end
    private_class_method :parse

    # Token-turns: what a spill saves is the bytes it withholds for every turn
    # the result would still have been carried, and what it costs when followed
    # is the pointer for those same turns plus one whole prefix re-read.
    def self.net(spills, floor)
      spills.sum do |spill|
        next 0 unless spill.bytes > floor

        if spill.read_back
          spill.bytes / 4.0 - (POINTER / 4.0) * spill.remaining - spill.prefix
        else
          ((spill.bytes - POINTER) / 4.0) * spill.remaining
        end
      end
    end

    FLOORS = [500, 1_500, 3_000, 6_000, 10_000, 16_000, 24_000, 40_000, 64_000].freeze

    def self.report(spills)
      return 'no spills found — has anything been spilled since the last state reset?' if spills.empty?

      [summary(spills), '', sweep(spills)].join("\n")
    end

    def self.summary(spills)
      back = spills.count(&:read_back)
      turns = spills.map(&:remaining).sort
      prefixes = spills.select(&:read_back).map(&:prefix).sort
      format("%d spills, %d read back (%.1f%%)\nturns still to carry: median %d · prefix at the read-back: median %d tokens",
             spills.size, back, 100.0 * back / spills.size, turns[turns.size / 2].to_i,
             prefixes.empty? ? 0 : prefixes[prefixes.size / 2])
    end
    private_class_method :summary

    # The floor is whichever column stops being negative and stays flat. Printed
    # rather than decided here: this is evidence for a constant in Mode, not a
    # constant itself.
    def self.sweep(spills)
      lines = [format('%8s %7s %11s %16s', 'floor', 'spills', 'roundtrips', 'net token-turns')]
      FLOORS.each do |floor|
        kept = spills.select { |spill| spill.bytes > floor }
        lines << format('%8d %7d %11d %+15.1fM', floor, kept.size, kept.count(&:read_back),
                        net(spills, floor) / 1_000_000.0)
      end
      lines << ''
      lines << "current floor: #{Mode::SPILL_BYTES}"
      lines.join("\n")
    end
    private_class_method :sweep
  end
end
