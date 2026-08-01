# frozen_string_literal: true

module LeanOutput
  module Compressors
    # `grep -rn` repeats the path on every hit. Forty hits in one file is forty
    # copies of "app/services/agents/claude_code.rb", which is the one thing in
    # the buffer the reader already knew after the first line. Factoring the
    # path out into a header keeps every line number and every matched line, so
    # unlike the other compressors here this one discards nothing at all.
    class Grep
      extend Spannable

      COMMAND = Regexp.union(Shell.word('[efz]?grep'), Shell.word('rg'), Shell.word('ack'))

      # The path has to carry a "/" or a "." or a clock qualifies: "10:00:00"
      # at the head of a log line parses as file "10", line 00. Requiring the
      # separator costs a root-level "Makefile:12:" and buys back every log.
      PATH = %r{[\w.+\-/~@]*[/.][\w.+\-/~@]*}
      HIT = /^(#{PATH}):(\d+):/
      CORE = HIT
      MIN_HITS = 5

      def self.lossless? = true

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      def self.output_match?(output)
        worth?(Text.plain(output))
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      # A path that never repeats has nothing to factor out, and a header per
      # file would leave the buffer bigger than it started. Checked again
      # against the span itself, not just the buffer, because the span is what
      # actually gets replaced.
      def self.worth?(text)
        files = text.lines.filter_map { |line| line[HIT, 1] }
        files.size >= MIN_HITS && files.uniq.size < files.size
      end

      # Rewrites in place instead of grouping globally: grep walks files in
      # order, so runs of one path already sit together, and streaming keeps the
      # "--" context separators and "grep: dir: Is a directory" notes exactly
      # where they were rather than herding them to the end.
      def self.summary(span)
        return nil unless worth?(span)

        current = nil

        span.each_line.with_object(+'') do |line, out|
          match = HIT.match(line)
          unless match
            current = nil
            next out << line
          end

          out << "#{match[1]}\n" if match[1] != current
          current = match[1]
          out << "  #{match[2]}:#{line[match.end(0)..]}"
        end
      end
    end
  end
end
