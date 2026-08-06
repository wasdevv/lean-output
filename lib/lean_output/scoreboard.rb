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
      lines.join("\n")
    end

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
