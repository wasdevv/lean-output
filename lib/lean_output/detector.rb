# frozen_string_literal: true

module LeanOutput
  # Picks the compressors that may claim a buffer. It no longer decides *which
  # one* wrote the text: each returns the span it recognises, and two spans that
  # overlap is what ambiguity now means. So a chain needs no command parsing —
  # `rspec && rubocop`, `bin/ci rspec rubocop` and a buffer whose command is
  # gone all resolve the same way, by reading the output.
  class Detector
    COMPRESSORS = [Compressors::Rspec, Compressors::Rubocop, Compressors::Brakeman, Compressors::GitDiff,
                   Compressors::Cargo, Compressors::Grep, Compressors::NodeTest].freeze
    # Cargo is absent on purpose: telling a rustc diagnostic from a successful
    # `cargo run` followed by the program's own stdout needs the subcommand, so
    # without a command there is no safe way to claim the output. Grep is absent
    # for the opposite reason — "path:line: text" is a shape half the tooling
    # world emits, and without a command naming grep there is nothing to say the
    # buffer is a hit list rather than a compiler's diagnostics.
    OUTPUT_DETECTABLE = [Compressors::Rspec, Compressors::Rubocop, Compressors::Brakeman,
                         Compressors::GitDiff].freeze
    # Structured output is not ours to rewrite: a compressor that drops a line
    # from JSON hands the next parser a syntax error, not a shorter document.
    #
    # The flag has to be a flag, and the value has to be the format. Anchored
    # to a word boundary and matched against the whole word, this used to be a
    # bare `/(-f|--format)[= ]?j/` scanning anywhere in the command, so any
    # filename starting with `j` disabled every compressor: `grep -f
    # jargon.txt` bailed, `cargo test --format junit` bailed on output that is
    # XML, and `bundle exec rspec | jq -f json` went from one claimant to none
    # with the rspec failures still in the buffer, unclaimed.
    JSON_FORMAT = /(?:\A|\s)(?:-f|--format)[= ](?:json|j)(?:\s|\z)/

    def self.for(command, output)
      return [] if command.match?(JSON_FORMAT)

      COMPRESSORS.select { |compressor| compressor.applicable?(command, output) }
    end

    # For callers holding text whose command is gone — a judge briefing, a CI
    # log, a saved buffer. Without a command there is nothing to gate on but the
    # output itself, so the list is narrower.
    def self.by_output(output)
      OUTPUT_DETECTABLE.select { |compressor| compressor.output_match?(output) }
    end
  end
end
