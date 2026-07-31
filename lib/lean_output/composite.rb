# frozen_string_literal: true

module LeanOutput
  # A check suite usually arrives as a single command: `rspec && rubocop &&
  # brakeman`. Every tool named in it claims the buffer, so Detector's
  # unambiguity rule hands back nil and the densest results of a run pass
  # through untouched.
  #
  # The doubt that rule guards against is *which tool wrote this text*. A command
  # naming three tools in three segments already answers it — all of them did.
  # So a composite is reachable only from the command path; `by_output`, where
  # the command is gone, still returns nil on two matches.
  class Composite
    SEGMENT = /&&|\|\||[;|\n]/

    def self.build(command, compressors)
      segments = command.split(SEGMENT).reject { |segment| segment.strip.empty? }
      owners = segments.map { |segment| compressors.select { |c| c.command_match?(segment) } }
      # One segment claimed by two tools is the ambiguity the rule exists for.
      return nil if owners.any? { |list| list.size > 1 }

      ordered = owners.flatten.uniq
      # A match owning no segment means the split misread the command — quoting,
      # a subshell, a heredoc. Passthrough rather than guess where it ran.
      return nil unless ordered.size == compressors.size

      new(ordered)
    end

    def initialize(compressors)
      @compressors = compressors
    end

    # Each compressor rewrites its own section and ignores the rest. One
    # returning nil means the buffer was not what the command implied, and
    # joining what is left would drop that tool's output without saying so.
    def compress(output)
      parts = @compressors.map { |compressor| compressor.compress(output) }
      return nil if parts.any?(&:nil?)

      parts.join("\n")
    end
  end
end
