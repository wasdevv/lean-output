# frozen_string_literal: true

module LeanOutput
  module Compressors
    # `node --test` prints TAP with a YAML block under every case, passing or
    # not. On a real run captured from Node 22, four tests came to 2,248 bytes
    # and two of them passed: each `ok` line drags `duration_ms`, `type` and a
    # pair of `---`/`...` markers, and each failure drags a stack of seven
    # frames where six are `node:internal/test_runner`.
    #
    # What a reader needs is the same three things every other compressor here
    # keeps: which cases failed, why, and the `file:line` to go to. The counts
    # at the bottom are the verdict and stay whole.
    #
    # The fixtures are captured from `node --test`, not written from memory —
    # this repo has already paid once for a fixture that matched what the code
    # expected instead of what the tool prints.
    class NodeTest
      extend Spannable

      COMMAND = /(?:\A|\s)node\b[^|;&]*--test|\bnode:test\b/
      # A TAP line for one case. `not ok` is what this exists for; `ok` is what
      # it removes.
      CORE = /^(?:not ok|ok) \d+ - /
      # The `1..N` plan and the `# tests`/`# pass`/`# fail` tail: the verdict.
      PLAN = /^\d+\.\.\d+$/
      COUNT = /^# (tests|suites|pass|fail|cancelled|skipped|todo|duration_ms) /
      # Node's own frames. A stack in a test failure is worth keeping only for
      # the frames in the user's code; the runner's internals are the same
      # seven lines in every failure ever printed.
      INTERNAL = /^\s*(?:async )?(?:Test|TestContext|TestHook)[\w.<>]*\s+\(node:|^\s*at node:/
      LOCATION = /^\s*location: '(.+)'$/
      MESSAGE = /^\s*(?:error|code|name|expected|actual|operator):\s*(.+)$/

      # The span is the whole TAP document: `TAP version 13` and the `# Subtest:`
      # headers sit before the first case line, and the YAML blocks, the plan
      # and the counts sit after the last one. Without both claims the region
      # stops at the first and last `ok`, which leaves the second failure's
      # YAML block outside the rewrite — printed raw, next to a summary that
      # claims to have covered it.
      HEADER = /^(?:TAP version \d+|# Subtest: )/
      YAML_LINE = /^\s+(?:---|\.\.\.|[\w]+:|at |async |[A-Z][\w.<>]*\s+\()/

      def self.back_claim = HEADER

      def self.forward_claim = Regexp.union(YAML_LINE, PLAN, COUNT, HEADER, CORE)

      def self.lossless? = false

      def self.discards = 'passing cases, TAP metadata, node-internal stack frames'

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      # A TAP version line plus at least one case is enough to be sure. Other
      # runners emit TAP too, and claiming their output would be wrong — so the
      # node-internal frames or the `# tests` tail have to be there as well,
      # and both are things only this runner prints.
      def self.output_match?(output)
        plain = Text.plain(output)
        plain.match?(/^TAP version 13$/) && plain.match?(CORE) &&
          (plain.match?(COUNT) || plain.match?(INTERNAL))
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      def self.summary(span)
        cases = failures(span)
        tail = span.lines.select { |line| line.match?(COUNT) || line.match?(PLAN) }
        return nil if cases.empty? && tail.empty?

        ([verdict(span)] + cases + tail.map(&:rstrip)).compact.join("\n")
      end

      # One line of counts, from the runner's own tail rather than recounted
      # here — a second implementation of "how many failed" is a second thing
      # that can disagree with the tool.
      def self.verdict(span)
        counts = span.lines.filter_map { |line| line[/^# (tests|pass|fail) (\d+)/, 0]&.delete_prefix('# ') }
        counts.empty? ? nil : "node --test: #{counts.join(', ')}"
      end
      private_class_method :verdict

      # Each failure as its identifying line, the fields that say what went
      # wrong, and the stack with the runner's own frames dropped.
      def self.failures(span)
        blocks(span).flat_map do |header, body|
          [header.rstrip, *detail(body)]
        end
      end
      private_class_method :failures

      # Walked rather than filtered, because `error: |-` opens a block whose
      # message is on the lines after it. Filtering line by line kept the
      # `|-` and threw the message away, which is the one thing a failure is
      # read for.
      def self.detail(body)
        in_error = false
        body.filter_map do |line|
          if line.match?(/^\s+error: \|-\s*$/)
            in_error = true
            next nil
          end
          if in_error
            next "   #{line.strip}" unless line.match?(/^\s+\w+:/) || line.match?(/^\s+\.\.\.\s*$/)

            in_error = false
          end
          keep(line)
        end
      end
      private_class_method :detail

      def self.keep(line)
        return "   at #{Regexp.last_match(1)}" if line.match(LOCATION)
        return nil if line.match?(INTERNAL)
        return "   #{line.strip}" if line.match?(MESSAGE)

        # A frame in the user's own code, which is the only kind worth keeping.
        "   #{line.strip}" if line.match?(%r{^\s+\S+ \(/}) && !line.match?(/node:/)
      end
      private_class_method :keep

      # A `not ok` line owns everything up to the next TAP line at the same
      # level. Split on the case lines rather than on the `---`/`...` markers,
      # because a nested subtest indents those and the marker stops being a
      # reliable fence.
      def self.blocks(span)
        span.lines.slice_before { |line| line.match?(CORE) }
                  .select { |chunk| chunk.first.start_with?('not ok') }
                  .map { |chunk| [chunk.first, chunk.drop(1)] }
      end
      private_class_method :blocks
    end
  end
end
