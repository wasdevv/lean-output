# frozen_string_literal: true

require_relative 'lean_output/text'
require_relative 'lean_output/budget'
require_relative 'lean_output/shell'
require_relative 'lean_output/region'
require_relative 'lean_output/splice'
require_relative 'lean_output/spannable'
require_relative 'lean_output/compressors/rspec'
require_relative 'lean_output/compressors/rubocop'
require_relative 'lean_output/compressors/brakeman'
require_relative 'lean_output/compressors/git_diff'
require_relative 'lean_output/compressors/cargo'
require_relative 'lean_output/compressors/grep'
require_relative 'lean_output/compressors/json_rows'
require_relative 'lean_output/detector'
require_relative 'lean_output/runner'

module LeanOutput
  VERSION = '0.8.0'

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

  # Whether every compressor claiming this text keeps what it replaces. The
  # hook uses it to pick the floor a rewrite has to clear before it is worth
  # swapping in: dropping a backtrace has to earn its risk of costing the reader
  # context, factoring out a repeated path owes nothing to that premium.
  def self.lossless?(text, command: nil)
    claimants = candidates(Text.plain(text.to_s), command)
    claimants.any? && claimants.all?(&:lossless?)
  end

  def self.rewrite(output, command)
    plain = Text.plain(output)
    rewrites = candidates(plain, command).filter_map { |compressor| compressor.rewrite(plain) }
    return nil if rewrites.empty?

    Splice.apply(plain, rewrites)
  end
  private_class_method :rewrite

  def self.candidates(plain, command)
    command ? Detector.for(command.to_s, plain) : Detector.by_output(plain)
  end
  private_class_method :candidates
end
