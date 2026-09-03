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

    Result = Struct.new(:tool, :command, :bytes, :saved, :claimed, :shape, keyword_init: true)

    # Tools this plugin has no compressor for, recognised by what they print.
    #
    # The roster is rspec, rubocop, brakeman, cargo, git diff and grep — one
    # ecosystem, chosen because it is the one whose output was on hand. On this
    # corpus compressors are 43% of everything saved, so for anyone working in
    # Python, JavaScript or Go that share is simply missing, and nothing in the
    # tool said so: `analyze` ranked their unclaimed output under `pytest` or
    # `npm` with no hint that a compressor was the thing it was missing.
    #
    # These patterns only ever write a line in a report. That is deliberate and
    # it is the whole reason they are allowed to be this rough: a false
    # positive here costs a suggestion, while the same guess inside `Detector`
    # would cost a rewrite of output nobody verified. Writing the compressor
    # still needs real captured output — the fixture for a foreign tool comes
    # from the tool, never from what we assume it prints.
    UNSUPPORTED = {
      'pytest' => /^=+ (FAILURES|ERRORS|short test summary) =+|^\d+ (passed|failed)/,
      'jest/vitest' => /^\s*(✕|✗|×)\s|^Tests:\s+\d+ failed|^ FAIL /,
      'go test' => /^--- FAIL: |^ok\s+\S+\s+[\d.]+s$/,
      'eslint' => /^✖ \d+ problems?|^\s+\d+:\d+\s+(error|warning)\s/,
      'tsc' => /error TS\d+:/,
      'pip/npm install' => /^(Collecting|Downloading|Requirement already satisfied|added \d+ packages)/
    }.freeze

    def self.shape_of(output)
      UNSUPPORTED.find { |_, pattern| output.match?(pattern) }&.first
    end

    # `since` in days, because a corpus spanning months mixes projects that no
    # longer resemble each other — the ranking answers "where were the bytes",
    # and the useful question is where they are now. `project` narrows to one
    # transcript directory for the same reason at the other axis: the optimum
    # floor for a Rails repo and for a video pipeline have no reason to agree,
    # and averaging them produces a number correct for neither.
    def self.analyze(root: DEFAULT_ROOT, limit: nil, since: nil, project: nil)
      files = transcripts(root, since: since, project: project)
      seen = 0
      files.flat_map do |file|
        break [] if limit && seen >= limit

        rows = ScanCache.fetch('corpus', file) { replay_file(file) }
        seen += rows.size
        rows.map { |row| Result.new(**row.transform_keys(&:to_sym)) }
      end
    end

    def self.transcripts(root, since: nil, project: nil)
      pattern = File.join(File.expand_path(root), project ? "*#{project}*" : '*', '*.jsonl')
      files = Dir.glob(pattern)
      return files unless since

      cutoff = Time.now.utc - (since * 86_400)
      files.select { |file| File.mtime(file) > cutoff }
    end

    # Which project each transcript belongs to, for the ranking that asks the
    # question one repo at a time.
    def self.projects(root: DEFAULT_ROOT)
      Dir.glob(File.join(File.expand_path(root), '*')).select { |path| File.directory?(path) }
         .map { |path| File.basename(path) }.sort
    end

    # One transcript at a time, each against its own state directory. The walk
    # used to share one temp state across every file, which was the shape of
    # the real thing but not its meaning: a transcript is a session, and two
    # sessions never see each other's ledger. Replaying them separately is both
    # more faithful and what lets a file's answer be memoised — a transcript
    # whose size and mtime have not moved cannot have a different answer, and
    # this replay is the ten minutes that made `calibrate` expensive enough to
    # run once and then trust for a year.
    def self.replay_file(file)
      rows = []
      Dir.mktmpdir('lean-output-corpus') do |state|
        with_state(state) do
          calls = {}
          File.foreach(file) do |line|
            record = parse(line) or next
            harvest(record, calls) { |payload| rows << replay(payload)&.to_h }
          end
        end
      end
      rows.compact
    end
    private_class_method :replay_file

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
       summary(groups.values.sum { |group| group[:bytes] }, results),
       *missing(results)].join("\n")
    end

    # Not a ranking, a shopping list: the tools whose output went past whole
    # because nothing here knows how to read it. Silent when the roster already
    # covers what you run, which is the common case and the reason it costs a
    # line rather than a section.
    def self.missing(results)
      shapes = results.reject(&:claimed).group_by(&:shape).except(nil)
      return [] if shapes.empty?

      ['', 'unclaimed output from tools with no compressor here:',
       *shapes.sort_by { |_, list| -list.sum(&:bytes) }.map do |shape, list|
         format('  %-18s %5d results  %6.2fMB', shape, list.size, mb(list.sum(&:bytes)))
       end]
    end
    private_class_method :missing

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
        saved: output.bytesize - after, claimed: !updated.nil?,
        shape: updated ? nil : shape_of(output)
      )
    end
    private_class_method :replay

    # Group by the shape of the command rather than the command, so 588 greps
    # for different strings answer as one line. `git diff` and `git status` stay
    # apart because the subcommand is what decides whether anything can claim it.
    #
    # The prefix has to come off first, and it comes in more shapes than one:
    # `cd X && …` was stripped and `cd X; …` was not, so 1196 calls and 1.00MB
    # of a real corpus ranked as a bucket called `cd` — a tenth of the whole
    # thing, hiding `python3`, `git status` and `bundle exec rspec` inside a row
    # that reads as unclaimable. An inline assignment does the same, and ranks
    # under `BUNDLE_LOCKFILE`. This only ever moved the ranking: what the hook
    # claims is decided by `Detector`, which reads the output.
    PREFIX = [/\A(cd|export|source)\s+\S+\s*(&&|;)\s*/m,   # a directory, then the real command
              /\A\w+=\S*\s+/m,                             # FOO=bar cmd
              /\A(env|timeout)\s+(-\S+\s+|\S+=\S*\s+|\d+\s+)*/m].freeze

    def self.label(payload)
      return payload['tool_name'].to_s unless payload['tool_name'] == 'Bash'

      command = strip_prefix(payload.dig('tool_input', 'command').to_s.strip)
      words = command.split(/\s+/).reject { |word| word.start_with?('-') }
      head = words.first.to_s.split('/').last
      %w[bundle bin npm cargo ruby git gh rails python3].include?(head) ? words.take(2).join(' ') : head
    end

    # Repeatedly, because the prefixes stack: `cd X; FOO=1 timeout 60 rspec`.
    def self.strip_prefix(command)
      loop do
        before = command
        PREFIX.each { |pattern| command = command.sub(pattern, '') }
        return command if command == before
      end
    end
    private_class_method :strip_prefix

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
