# frozen_string_literal: true

require 'json'
require 'tmpdir'

module LeanOutput
  # What this plugin would have done to work that already happened.
  #
  # Every threshold in Mode cites a measurement, and every one of those
  # measurements was taken once, by hand, against whatever transcripts were
  # around that afternoon. This turns that into something the user can re-run
  # against their own history — which matters because the answer is not
  # universal: the compressor roster targets rspec, rubocop, brakeman and cargo,
  # and on the corpus that prompted this file those four are 5% of the bytes
  # while grep, cat, env, ls and sed are 45%.
  #
  # The replay feeds real payloads back through Runner rather than re-deriving
  # the decision. A second implementation of "what would it have saved" is a
  # second thing that can be wrong about the host, and this repo has already
  # paid for that mistake once — see spec/shape_spec.rb.
  module Corpus
    DEFAULT_ROOT = '~/.claude/projects'

    Result = Struct.new(:tool, :command, :bytes, :saved, :claimed, keyword_init: true)

    def self.analyze(root: DEFAULT_ROOT, limit: nil)
      results = []
      Dir.mktmpdir('lean-output-corpus') do |state|
        with_state(state) { each_result(root, limit) { |payload| results << replay(payload) } }
      end
      results.compact
    end

    # Ranked by what is left on the table, not by what was saved. A compressor
    # that already works is not where the next one should go; the top of this
    # list is, and it is the number the roster was never checked against.
    def self.report(results, rows: 12)
      return 'no tool results found — is the transcript root right?' if results.empty?

      groups = results.group_by(&:command).transform_values { |list| tally(list) }
      total = groups.values.sum { |group| group[:bytes] }
      lines = [format('%-20s %7s %9s %9s %8s', 'command', 'calls', 'MB', 'saved', 'unclaimed')]
      groups.sort_by { |_, group| -(group[:bytes] - group[:saved]) }.first(rows).each do |name, group|
        lines << row(name, group)
      end
      lines << ''
      lines << summary(total, results)
      lines.join("\n")
    end

    def self.tally(list)
      { calls: list.size, bytes: list.sum(&:bytes), saved: list.sum(&:saved),
        claimed: list.count(&:claimed) }
    end
    private_class_method :tally

    def self.row(name, group)
      left = group[:bytes] - group[:saved]
      format('%-20s %7d %9.2f %8d%% %8.2fMB', name, group[:calls], mb(group[:bytes]),
             group[:bytes].zero? ? 0 : (100.0 * group[:saved] / group[:bytes]).round, mb(left))
    end
    private_class_method :row

    def self.summary(total, results)
      saved = results.sum(&:saved)
      claimed = results.count(&:claimed)
      format('%d results, %.2fMB → %.2fMB (-%d%%); %d of %d claimed (%d%%)',
             results.size, mb(total), mb(total - saved),
             total.zero? ? 0 : (100.0 * saved / total).round,
             claimed, results.size, (100.0 * claimed / results.size).round)
    end
    private_class_method :summary

    def self.mb(bytes)
      bytes / 1024.0 / 1024
    end
    private_class_method :mb

    # The replay writes ledger entries, and they must not land in the state dir
    # the user's live sessions are reading.
    def self.with_state(dir)
      previous = ENV.fetch('LEAN_OUTPUT_STATE_DIR', nil)
      ENV['LEAN_OUTPUT_STATE_DIR'] = dir
      yield
    ensure
      ENV['LEAN_OUTPUT_STATE_DIR'] = previous
    end
    private_class_method :with_state

    def self.replay(payload)
      output = Runner.extract_output(payload['tool_response']).to_s
      return nil if output.empty?

      updated = Runner.call(payload)&.dig('hookSpecificOutput', 'updatedToolOutput')
      after = updated ? Runner.extract_output(updated).to_s.bytesize : output.bytesize
      Result.new(
        tool: payload['tool_name'], command: label(payload), bytes: output.bytesize,
        saved: output.bytesize - after, claimed: !updated.nil?
      )
    end
    private_class_method :replay

    # Group by the shape of the command rather than the command, so 588 greps
    # for different strings answer as one line. `git diff` and `git status` stay
    # apart because the subcommand is what decides whether anything can claim it.
    def self.label(payload)
      return payload['tool_name'].to_s unless payload['tool_name'] == 'Bash'

      command = payload.dig('tool_input', 'command').to_s.strip.sub(/\A(cd|env)\s+\S+\s*&&\s*/, '')
      words = command.split(/\s+/).reject { |word| word.start_with?('-') }
      head = words.first.to_s.split('/').last
      %w[bundle bin npm cargo ruby git gh rails].include?(head) ? words.take(2).join(' ') : head
    end

    # Walks the transcripts pairing each tool_use with the result that came
    # back. `toolUseResult` is the response in the shape the host actually
    # returned, which is the only reason this replay is worth anything.
    def self.each_result(root, limit)
      seen = 0
      Dir.glob(File.join(File.expand_path(root), '*', '*.jsonl')).each do |file|
        calls = {}
        File.foreach(file) do |line|
          record = parse(line) or next
          harvest(record, calls) do |payload|
            yield payload
            seen += 1
          end
          return if limit && seen >= limit
        end
      end
    end
    private_class_method :each_result

    def self.harvest(record, calls)
      blocks = record.dig('message', 'content')
      return unless blocks.is_a?(Array)

      blocks.each do |block|
        next unless block.is_a?(Hash)

        case block['type']
        when 'tool_use' then calls[block['id']] = block
        when 'tool_result'
          call = calls.delete(block['tool_use_id']) or next
          response = record['toolUseResult'] or next
          yield payload_for(record, call, response)
        end
      end
    end
    private_class_method :harvest

    def self.payload_for(record, call, response)
      {
        'hook_event_name' => 'PostToolUse',
        'session_id' => record['sessionId'].to_s,
        'cwd' => record['cwd'].to_s,
        'tool_name' => call['name'].to_s,
        'tool_input' => call['input'] || {},
        'tool_response' => response
      }
    end
    private_class_method :payload_for

    def self.parse(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end
    private_class_method :parse
  end
end
