# frozen_string_literal: true

require_relative 'lean_output/text'
require_relative 'lean_output/budget'
require_relative 'lean_output/compressors/rspec'
require_relative 'lean_output/compressors/rubocop'
require_relative 'lean_output/compressors/brakeman'
require_relative 'lean_output/compressors/git_diff'
require_relative 'lean_output/compressors/cargo'
require_relative 'lean_output/compressors/json_rows'
require_relative 'lean_output/composite'
require_relative 'lean_output/detector'
require_relative 'lean_output/runner'

module LeanOutput
  VERSION = '0.6.0'

  # Entry point for callers outside the Claude Code hook: agent orchestrators
  # injecting tool output into a prompt, CI scripts, log processors.
  #
  # Always returns a String — passthrough returns the input itself, and an
  # unexpected error degrades to the input rather than raising, so a caller can
  # drop this in wherever it used to truncate.
  #
  #   LeanOutput.compress(stdout, command: "bundle exec rspec", budget: 8_000)
  #
  # `command` is optional; without it the text alone has to identify the tool
  # unambiguously. `budget` is a byte ceiling honoured by dropping whole
  # entries, never by cutting through one. The hook's own thresholds (minimum
  # line count, minimum saving) are policy in Runner, not here: a caller asking
  # for compression has already decided the text is too long.
  def self.compress(text, command: nil, budget: nil, footer: false)
    original = text.to_s
    rewritten = rewrite(original, command)
    result = rewritten ? Budget.fit(rewritten, budget) : original
    result = Budget.clip(result, budget)

    return result if result.equal?(original) || !footer

    result + Runner.footer(original.bytesize, result.bytesize)
  rescue StandardError
    text.to_s
  end

  def self.rewrite(output, command)
    compressor = command ? Detector.for(command.to_s, output) : Detector.by_output(output)
    compressor&.compress(output)
  end
  private_class_method :rewrite
end
