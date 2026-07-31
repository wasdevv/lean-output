# frozen_string_literal: true

module LeanOutput
  class Detector
    COMPRESSORS = [Compressors::Rspec, Compressors::Rubocop, Compressors::Brakeman, Compressors::GitDiff, Compressors::Cargo].freeze
    # Cargo is absent on purpose: telling a rustc diagnostic from a successful
    # `cargo run` followed by the program's own stdout needs the subcommand, so
    # without a command there is no safe way to claim the output.
    OUTPUT_DETECTABLE = [Compressors::Rspec, Compressors::Rubocop, Compressors::Brakeman, Compressors::GitDiff,
                         Compressors::JsonRows].freeze
    JSON_FORMAT = /(-f|--format)[= ]?j/

    def self.for(command, output)
      return nil if command.match?(JSON_FORMAT)

      matches = COMPRESSORS.select { |compressor| compressor.applicable?(command, output) }
      return matches.first if matches.size == 1
      return nil if matches.empty?

      # More than one tool claims the buffer. When the command ran them in
      # separate segments that is not ambiguity, it is a chain — see Composite.
      Composite.build(command, matches)
    end

    # For callers holding text whose command is gone — a judge briefing, a CI
    # log, a saved buffer. Same unambiguity rule as `for`: two candidates means
    # passthrough.
    def self.by_output(output)
      matches = OUTPUT_DETECTABLE.select { |compressor| compressor.output_match?(output) }
      matches.size == 1 ? matches.first : nil
    end
  end
end
