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
      ranked = groups.sort_by { |_, group| -(group[:bytes] - group[:saved]) }.first(rows)

      [format('%-20s %7s %9s %9s %8s', 'command', 'calls', 'MB', 'saved', 'unclaimed'),
       *ranked.map { |name, group| row(name, group) },
       '',
       *bands(results),
       '',
       summary(groups.values.sum { |group| group[:bytes] }, results)].join("\n")
    end

    # The same residue by result size, because *which rung can reach it* is a
    # question about size, not about which command produced it. The ranking above
    # says what to write; this says whether to write anything at all — a residue
    # sitting under the vault floor is one no pointer will ever take, and one
    # under `min_bytes` is one no rung looks at.
    #
    # The edges are the live thresholds rather than round numbers, so moving a
    # floor in Mode moves this table with it and the two cannot disagree.
    def self.bands(results)
      floor = POLICY_FLOOR
      edges = [floor, Mode::SPILL_BYTES]
      counted = results.group_by { |result| edges.count { |edge| result.bytes >= edge } }
      names = ["under #{Text.human(floor)} — no rung looks",
               "#{Text.human(floor)}–#{Text.human(Mode::SPILL_BYTES)} — compressors only",
               "over #{Text.human(Mode::SPILL_BYTES)} — the vault takes it"]
      left = results.sum { |result| result.bytes - result.saved }

      names.each_with_index.map { |name, index| band_row(name, counted[index] || [], left) }
    end

    # Every level shares one floor; this reads it rather than restating it.
    POLICY_FLOOR = Mode::POLICY.fetch('full').fetch(:min_bytes)

    def self.band_row(name, list, left)
      unclaimed = list.sum { |result| result.bytes - result.saved }
      format('%-34s %7d calls %8.2fMB left %6d%%', name, list.size, mb(unclaimed),
             left.zero? ? 0 : (100.0 * unclaimed / left).round)
    end
    private_class_method :band_row

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
    #
    # This ranking is what picks the next compressor, so a label that names the
    # wrong thing does not merely misreport — it aims the work. Stripping only
    # `cd X &&` was that mistake: over 61 real projects it filed 814 results
    # under `cd`, 408 under `export` and 315 under a shell variable, and every
    # tool behind those prefixes was invisible to the ranking. `mix` did not
    # appear at all, hidden behind the `export PATH=…;` its own runner needs.
    #
    # So the prefixes come off until something that is not a prefix is left:
    # a directory change, an assignment, an `env`/`export` — separated by `;`
    # as well as `&&`, since a setup step that must not gate the real command is
    # exactly what a `;` is for.
    #
    # A leading assignment is the one that needs no separator at all:
    # `RAILS_ENV=test bundle exec rspec` is one command with a prefix, and by
    # shell rules a first word containing `=` can only be that. The value may be
    # empty — `BUNDLE_LOCKFILE= bundle exec rspec` is how you unset one for a
    # single call, and it hid 362 results behind a label that was an equals sign.
    SETUP = /\A(?:(?:cd\s+\S+|env(?:\s+\w+=\S*)+|export\s+[^;&|]+)\s*(?:;|&&)\s*|\w+=\S*\s*(?:;|&&)?\s+)/
    # Runners whose first word says nothing: the subcommand is the tool.
    RUNNERS = %w[bundle bin npm npx pnpm yarn cargo ruby python3 python node git gh rails
                 mix docker kubectl make go dotnet composer php artisan].freeze
    # Neither a flag nor a subcommand: redirections and heredocs are the shell
    # talking about the command, and taking one as the subcommand produced
    # `python3 <<'PY'` as a heading over 899 results.
    SYNTAX = /\A[-<>|&]/

    def self.label(payload)
      return payload['tool_name'].to_s unless payload['tool_name'] == 'Bash'

      command = payload.dig('tool_input', 'command').to_s.strip
      # Bounded rather than `while`: a pathological command must not spin here,
      # and four setup steps in front of one tool is already unusual.
      4.times { command = command.sub(SETUP, '') }
      # Only the first line names the command. Past it is the heredoc body, and
      # reading that gave `python3 import` — a label naming a Python keyword.
      words = command.lines.first.to_s.split(/\s+/).grep_v(SYNTAX)
      head = words.first.to_s.split('/').last
      RUNNERS.include?(head) ? words.take(2).join(' ') : head
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
