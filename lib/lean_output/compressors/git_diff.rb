# frozen_string_literal: true

module LeanOutput
  module Compressors
    class GitDiff
      extend Spannable

      COMMAND = Shell.word('git(?:\s+-\S+(?:\s+\S+)?)*\s+(?:diff|show)')
      HEADER = /^diff --git /
      SPLIT = /^(?=diff --git )/

      # Structural lines only. Hunk bodies are reached by growth instead: a
      # context line is just an indented line of source, and claiming that
      # shape outright would let the span reach backwards into whatever ran
      # before the diff.
      CORE = Regexp.union(
        HEADER,
        /^index [0-9a-f]/,
        %r{^--- (a/|/dev/null)},
        %r{^\+\+\+ (b/|/dev/null)},
        /^@@ /,
        /^(old|new|deleted) (file )?mode /,
        /^similarity index /,
        /^rename (from|to) /,
        /^Binary files /,
        /^GIT binary patch$/
      )

      # The tail of the last hunk carries no marker, so contiguity is the only
      # signal left. This is the weakest claim in the gem: `git diff && cat
      # indented_file` would have the file's first lines absorbed. A diff is
      # nearly always the last thing on a command line, which is what makes the
      # trade acceptable.
      BODY = /^([-+ \\]|$)/

      def self.forward_claim
        BODY
      end

      # Files a reviewer never reads line by line: they are regenerated from a
      # source that is itself in the diff.
      COLLAPSIBLE = Regexp.union(
        %r{(^|/)(vendor|node_modules|dist|coverage)/},
        %r{^app/assets/builds/},
        %r{(^|/)(Gemfile\.lock|Cargo\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|composer\.lock|poetry\.lock|go\.sum|flake\.lock)$},
        %r{^db/structure\.sql$},
        /\.min\.(js|css)$/,
        /\.map$/
      )

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      def self.output_match?(output)
        Text.plain(output).match?(HEADER)
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      def self.summary(plain)
        parts = plain.split(SPLIT)
        # split drops nothing when the string opens with the pattern, so the
        # first part is a real preamble only when it is not itself a diff block.
        preamble = parts.first.to_s.match?(HEADER) ? '' : parts.shift.to_s
        return nil if parts.empty?

        collapsed = 0
        blocks = parts.map do |block|
          path = path_for(block)
          next block unless path&.match?(COLLAPSIBLE)

          collapsed += 1
          collapse(block)
        end

        return nil if collapsed.zero?

        preamble + blocks.join
      end

      def self.path_for(block)
        block[%r{^\+\+\+ b/(.+)$}, 1] || block[%r{^--- a/(.+)$}, 1] || block[%r{^diff --git a/(.+?) b/}, 1]
      end

      def self.collapse(block)
        header = block.lines.first
        added = block.lines.count { |line| line.start_with?('+') && !line.start_with?('+++') }
        removed = block.lines.count { |line| line.start_with?('-') && !line.start_with?('---') }

        "#{header}[lean-output] generated file — +#{added}/-#{removed} lines, body collapsed\n"
      end
    end
  end
end
