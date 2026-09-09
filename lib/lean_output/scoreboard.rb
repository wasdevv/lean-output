# frozen_string_literal: true

require 'json'

module LeanOutput
  # What the plugin actually saved, read back from the session files it writes
  # on every tool call.
  #
  # A benchmark measures a corpus someone chose; this measures the session the
  # user is in. The two disagree often enough to be worth printing — a session
  # spent in one long `git log` is nothing like the fixture mix, and the honest
  # answer to "is this worth having installed" is the second number.
  module Scoreboard
    # Roughly four bytes to a token for the tool output this sees — banners,
    # paths and stack frames, not prose. Deliberately approximate: the point is
    # the order of magnitude, and a tokenizer dependency to sharpen a figure
    # nobody bills against would not pay for itself.
    BYTES_PER_TOKEN = 4.0

    def self.render(cwd = nil)
      current = read(newest_for(cwd))
      lines = ["  this session   #{summarise(current)}"]
      lines << "  all sessions   #{summarise(total)}" if files.size > 1
      compared = strata
      lines << "  re-run rate    #{reruns(compared)}" unless compared.empty?
      lines.join("\n")
    end

    # Printed as a pair or not at all. On its own, "8% of rewrites were followed
    # by the same command again" reads like a harm figure; beside the same
    # number for the results left untouched it reads like what it is.
    #
    # And summed over command families that have a sample in both arms, never
    # pooled. A pooled pair on a real corpus reads 53.2% against 30.4% and every
    # one of those twenty-three points is the rewritten arm being test runners.
    # The family count is printed because it is the sample size that matters
    # here: two families compared is not a measurement, and a reader who cannot
    # see how many were compared cannot tell.
    def self.reruns(strata)
      rewrites = strata.sum { |cell| cell[0].to_i }
      others = strata.sum { |cell| cell[2].to_i }
      "#{percent_of(strata.sum { |cell| cell[1].to_i }, rewrites)} after a rewrite, " \
        "#{percent_of(strata.sum { |cell| cell[3].to_i }, others)} after a passthrough " \
        "(within #{Session::WATCH_CALLS} calls, across #{plural(strata.size)})"
    end
    private_class_method :reruns

    def self.plural(count)
      count == 1 ? '1 command family' : "#{count} command families"
    end
    private_class_method :plural

    # Cells are merged across sessions before the both-arms test, not after: a
    # family rewritten in one session and passed through in another is a
    # comparison the pair of sessions can make and neither can alone.
    def self.strata
      merged = Hash.new { |hash, key| hash[key] = Array.new(Session::CELL, 0) }
      files.each do |file|
        meter(file).each do |family, cell|
          next unless cell.is_a?(Array) && cell.size == Session::CELL

          Session::CELL.times { |i| merged[family][i] += cell[i].to_i }
        end
      end
      merged.values.select { |cell| cell[0].positive? && cell[2].positive? }
    end
    private_class_method :strata

    def self.meter(file)
      parsed = JSON.parse(File.read(file))
      parsed.is_a?(Hash) && parsed['meter'].is_a?(Hash) ? parsed['meter'] : {}
    rescue StandardError
      {}
    end
    private_class_method :meter

    def self.percent_of(count, total)
      total.zero? ? 'n/a' : "#{(100.0 * count.to_i / total).round(1)}%"
    end
    private_class_method :percent_of

    def self.summarise(gain)
      calls = gain['calls'].to_i
      return 'nothing measured yet' if calls.zero?

      before = gain['before'].to_i
      saved = before - gain['after'].to_i
      "#{calls} #{calls == 1 ? 'result' : 'results'}, #{Text.human(before)} → #{Text.human(gain['after'].to_i)} " \
        "(#{percent(saved, before)}, ~#{tokens(saved)} tokens)#{ledger_share(gain)}"
    end

    def self.ledger_share(gain)
      hits = gain['hits'].to_i
      return '' if hits.zero?

      ", #{hits} already in context (#{Text.human(gain['hit_bytes'].to_i)})"
    end
    private_class_method :ledger_share

    def self.percent(saved, before)
      before.zero? ? '0%' : "-#{(100.0 * saved / before).round}%"
    end
    private_class_method :percent

    def self.tokens(bytes)
      count = (bytes / BYTES_PER_TOKEN).round
      count < 1_000 ? count.to_s : "#{(count / 1000.0).round(1)}k"
    end
    private_class_method :tokens

    def self.total
      files.map { |file| read(file) }.each_with_object(Session.gain_blank) do |gain, sum|
        sum.each_key { |key| sum[key] += gain[key].to_i }
      end
    end

    # The session id is not knowable from a shell command, so "this session" is
    # the file the last tool call touched. It is a guess, and it is right in the
    # only case that matters: the user asking right after working.
    def self.newest_for(cwd)
      by_cwd = files.find { |file| File.basename(file, '.json') == Session.identify('cwd' => cwd.to_s) }
      by_cwd || files.max_by { |file| File.mtime(file) }
    end
    private_class_method :newest_for

    def self.files
      Dir.glob(File.join(Session.dir, '*.json'))
    end
    private_class_method :files

    def self.read(file)
      return Session.gain_blank unless file

      parsed = JSON.parse(File.read(file))
      parsed.is_a?(Hash) && parsed['gain'].is_a?(Hash) ? parsed['gain'] : Session.gain_blank
    rescue StandardError
      Session.gain_blank
    end
    private_class_method :read
  end
end
