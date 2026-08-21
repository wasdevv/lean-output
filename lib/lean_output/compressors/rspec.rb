# frozen_string_literal: true

module LeanOutput
  module Compressors
    class Rspec
      extend Spannable

      COMMAND = Shell.word('rspec')
      SUMMARY = /^\d+ examples?, \d+ failures?.*$/
      GEM_FRAME = %r{/gems/|/rubies/|/ruby/\d}
      SUPPORT_FRAME = %r{\./spec/support/}
      MAX_MESSAGE_LINES = 6

      # Lines no other tool in a check suite writes. Failure bodies need no
      # entry of their own: they sit between "Failures:" and "Finished in".
      CORE = Regexp.union(
        /^Failures:$/,
        /^Pending:$/,
        /^Finished in /,
        SUMMARY,
        /^Failed examples:$/,
        /^rspec \S+ # /,
        /^Randomized with seed \d+$/,
        /^Top \d+ slowest/,
        /^Coverage report generated/,
        /^(Line|Branch) Coverage: /,
        /^Stopped processing SimpleCov/
      )

      # The progress line names no tool, and it runs *before* the first line
      # that does — so it is only reachable by growing backwards. Its alphabet
      # overlaps RuboCop's, but RuboCop opens with "Inspecting N files", which
      # anchors its span ahead of its own dots; neither can reach the other's.
      PROGRESS = /^[.FE*]{3,}$/

      def self.back_claim
        PROGRESS
      end

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      def self.output_match?(output)
        Text.plain(output).match?(SUMMARY)
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      def self.discards = 'passing examples, gem backtrace frames'

      def self.summary(plain)
        summary = plain[SUMMARY] or return nil
        finished = plain[/^Finished in .+$/]&.sub(/ \(files took.*\)/, '')
        reruns = plain.scan(/^rspec (\S+) # .*$/).flatten

        head = "RSpec: #{summary}#{" — #{finished}" if finished}"
        failures = parse_failures(plain).each_with_index.map { |failure, i| format_failure(failure, i, reruns[i]) }

        "#{[head, *failures].join("\n\n")}\n"
      end

      # The rerun command is the one thing here the model cannot reconstruct
      # from the rest, so it rides on the description line rather than below it.
      def self.format_failure(failure, index, rerun)
        out = +"#{index + 1}) #{failure[:description]}"
        out << "  (rspec #{rerun})" if rerun
        out << "\n   Failure/Error: #{failure[:error]}" if failure[:error]
        failure[:message].each { |line| out << "\n   #{line}" }
        out << "\n   at #{failure[:frame]}" if failure[:frame]
        out
      end
      private_class_method :format_failure

      def self.parse_failures(plain)
        section = plain[/^Failures:\n(.*?)(?=^(?:Failed examples:|Pending:|Top \d+ slowest|Finished in ))/m, 1]
        return [] unless section

        section.split(/^ {2}(?=\d+\) )/)
               .reject { |entry| entry.strip.empty? }
               .map { |entry| parse_entry(entry) }
      end

      # Three independent readings of the same lines, which is what the four
      # mutable locals and the `in_diff` flag were simulating in one pass. They
      # are independent in a way worth stating: the diff gate stops the
      # *message* and nothing else, so a backtrace frame printed after a Diff:
      # block still names the failing line — collapsing all three into one
      # `take_while` would silently lose it.
      def self.parse_entry(entry)
        lines = entry.lines.map(&:chomp)
        description = lines.shift.to_s.sub(/^\s*\d+\) /, '').strip
        body = lines.map(&:strip).reject(&:empty?)

        { description: description,
          error: body.find { |line| line.start_with?('Failure/Error:') }&.delete_prefix('Failure/Error:')&.strip,
          message: message_lines(body),
          frame: app_frame(body) }
      end

      # Everything rspec printed that was not a frame, the error line, or the
      # diff it renders after them — capped, because a message this long has
      # stopped being a message.
      def self.message_lines(body)
        body.take_while { |line| line != 'Diff:' }
            .reject { |line| line.start_with?('# ', 'Failure/Error:') || line == '(compared using ==)' }
            .first(MAX_MESSAGE_LINES)
      end
      private_class_method :message_lines

      # The first frame that belongs to the project. A backtrace opens with the
      # gem that raised and the support file that wrapped it, and neither is
      # where anyone goes to fix the test.
      def self.app_frame(body)
        body.filter_map { |line| line.delete_prefix('# ').sub(/:in .*/, '') if line.start_with?('# ') }
            .find { |path| !path.match?(GEM_FRAME) && !path.match?(SUPPORT_FRAME) }
      end
      private_class_method :app_frame
    end
  end
end
