# frozen_string_literal: true

require 'json'

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

    Result = Struct.new(:tool, :command, :bytes, :saved, :claimed, :shape, :structure, :packed,
                        :input, :trimmed, keyword_init: true)

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
      # `node --test` and `python -m unittest` have compressors now, so what is
      # left under these names is the runner this plugin still cannot read.
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
    def self.analyze(root: DEFAULT_ROOT, limit: nil, since: nil, project: nil, level: nil)
      files = transcripts(root, since: since, project: project)
      seen = 0
      at_level(level) do
        files.flat_map do |file|
          break [] if limit && seen >= limit

          # The level is part of the key, not just of the run. A memo keyed only
          # by the file would hand `full` the answer `volatile` computed, which
          # is the exact comparison the caller asked for and would have got
          # silently wrong.
          rows = ScanCache.fetch("corpus-#{level || 'resolved'}", file) { replay_file(file) }
          seen += rows.size
          rows.map { |row| Result.new(**row.transform_keys(&:to_sym)) }
        end
      end
    end

    # Forces one level for the whole replay. `Mode.resolve` reads the env before
    # anything else, which is the same door the kill switch uses, so this needs
    # no special case inside the ladder.
    def self.at_level(level)
      return yield unless level

      previous = ENV.fetch('LEAN_OUTPUT_MODE', nil)
      ENV['LEAN_OUTPUT_MODE'] = level
      yield
    ensure
      ENV['LEAN_OUTPUT_MODE'] = previous if level
    end
    private_class_method :at_level

    # What each level would have done to the same corpus, which is the question
    # behind "which level should I be on" and has only ever been answerable by
    # switching and waiting a week. Off is not replayed: it is the input.
    def self.compare(root: DEFAULT_ROOT, since: nil, project: nil)
      (Mode::LEVELS - %w[off]).filter_map do |level|
        results = analyze(root: root, since: since, project: project, level: level)
        next if results.empty?

        total = results.sum(&:bytes)
        [level, total, results.sum(&:saved), results.count(&:claimed), results.size]
      end
    end

    def self.comparison(rows)
      return 'no tool results found — is the transcript root right?' if rows.empty?

      [format('%-10s %9s %9s %8s %10s', 'level', 'MB in', 'MB out', 'saved', 'rewritten'),
       *rows.map do |level, total, saved, claimed, count|
         format('%-10s %9.2f %9.2f %7d%% %6d/%d', level, mb(total), mb(total - saved),
                total.zero? ? 0 : (100.0 * saved / total).round, claimed, count)
       end]
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
      # Required here rather than at the top, because `tmpdir` pulls in
      # `fileutils` and this file is loaded by the hook, which runs on every
      # tool call and never replays anything. The two together were 7.7ms of a
      # 31ms hook — a quarter of it, spent loading a dependency of a command
      # nobody ran.
      require 'tmpdir'
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
       *surface(results),
       *trimming(results),
       *bands(results),
       *missing(results)].join("\n")
    end

    # A command that trims its own output before the hook ever sees it. Rough on
    # purpose and it only ever writes a line in a report — the same licence the
    # UNSUPPORTED patterns get, and for the same reason.
    SELF_TRIMMED = /\|\s*(head|tail|wc|cut|awk|sed -n|grep|jq|sort|uniq|column)\b|\bhead -|\btail -|--quiet|\s-q\b/

    # Why the saving is what it is, which no other line here explains.
    #
    # A compressor is built for `bundle exec rspec` dumping 4.6 kB into the
    # context. It never sees that when the agent writes `bundle exec rspec 2>&1
    # | tail -40` — what arrives is 500 bytes of tail, already distilled, and
    # already missing the head where rspec puts the failure descriptions. The
    # rung did not fail; it was handed a fragment.
    #
    # Measured over 90 days of one machine: 75% of Bash calls arrive self-
    # trimmed, carrying 65% of the bytes at a 563B median against 949B for the
    # rest. That is the single biggest reason a real corpus reports a fraction
    # of the bench, and until this line existed the report gave no way to tell
    # "the compressors have nothing left" from "the compressors never got a
    # look".
    def self.trimming(results)
      trimmed = results.select(&:trimmed)
      return [] if trimmed.empty?

      bytes = results.sum(&:bytes)
      ['', format('%d%% of these commands trimmed their own output before the hook saw it ' \
                  '(| head, | tail, -q): %d of %d calls, %d%% of the bytes. A compressor handed ' \
                  'a tail cannot do better than the tail.',
                  (100.0 * trimmed.size / results.size).round, trimmed.size, results.size,
                  bytes.zero? ? 0 : (100.0 * trimmed.sum(&:bytes) / bytes).round)]
    end
    private_class_method :trimming

    # The denominator, which this report has never printed and which makes -3%
    # read as a failure rather than as a share.
    #
    # A tool call is an assistant message: the command, the file content a Write
    # carries, the strings an Edit replaces. It is in the context for the rest
    # of the session on exactly the same terms as the result, and **no hook
    # rewrites it** — PostToolUse arrives after it was sent, and nothing else
    # here runs earlier. So it is not a rung this plugin is missing, it is the
    # half of the surface that is out of reach, and a saving quoted against the
    # other half alone is quoted against a number the reader will assume is the
    # whole thing.
    def self.surface(results)
      calls = results.sum { |result| result.input.to_i }
      return [] if calls.zero?

      output = results.sum(&:bytes)
      ['', format('%.2fMB of this is tool output, the half a hook can rewrite. The tool *calls* that ' \
                  'produced it are %.2fMB (%d%% of the two) and no hook reaches them — they are ' \
                  'assistant messages, already sent.', mb(output), mb(calls),
                  (100.0 * calls / (calls + output)).round)]
    end
    private_class_method :surface

    # Where the leftover bytes sit relative to the rungs that could reach them,
    # which is the question the ranking above cannot answer. A row at the top
    # with 2MB unclaimed means "write a compressor" only if those bytes are in
    # the middle band; below the floor nothing looks at them, and above the
    # spill the vault already offers to take them and was declined for reasons
    # the vault sweep has already priced.
    #
    # The bounds come from the policy rather than from constants repeated here,
    # and the comparisons match the runtime's exactly — `deduplicable?` is
    # `>= min_bytes` and `Vault.spill` is `> spill` — so the report cannot
    # promise a reach the ladder does not have.
    def self.bands(results)
      policy = Mode.policy(Mode.resolve) or return []
      floor = policy[:min_bytes].to_i
      spill = policy[:spill]
      rows = [["under #{Text.human(floor)}", results.select { |result| result.bytes < floor }],
              [band_label(floor, spill),
               results.select { |result| result.bytes >= floor && !above?(result, spill) }]]
      # No spill key means no vault at this level, and a band nothing can reach
      # is a row with nothing to say.
      rows << ["over #{Text.human(spill)}", results.select { |result| above?(result, spill) }] if spill
      left = results.sum { |result| result.bytes - result.saved }

      ['', 'bytes still on the table, by which rung can reach them:',
       *rows.map { |name, list| band_row(name, list, left) },
       *ceiling(results)]
    end
    private_class_method :bands

    # The line that stops the ranking from reading as a roadmap. A band holding
    # most of the residue is only an opportunity if the bytes in it have
    # something a compressor could take, and until now nothing here said whether
    # they did — which is an afternoon of hand-written probes every time the
    # question comes up.
    def self.ceiling(results)
      bytes = results.sum(&:bytes)
      return [] if bytes.zero?

      ['  structure is repeated lines and shared prefixes — the only thing a readable rewrite banks.',
       format('  deflate takes -%d%% of the same bytes: the ceiling, and not a collectable one, ' \
              'since its output is not text.', 100 - (100.0 * results.sum { |r| r.packed.to_i } / bytes).round)]
    end
    private_class_method :ceiling

    def self.above?(result, spill)
      spill ? result.bytes > spill : false
    end
    private_class_method :above?

    def self.band_label(floor, spill)
      spill ? "#{Text.human(floor)}–#{Text.human(spill)}" : "over #{Text.human(floor)}"
    end
    private_class_method :band_label

    def self.band_row(name, list, left)
      remaining = list.sum { |result| result.bytes - result.saved }
      bytes = list.sum(&:bytes)
      format('  %-14s %6d calls  %8.2fMB left  %3d%% of the residue  %3d%% structure', name, list.size,
             mb(remaining), left.zero? ? 0 : (100.0 * remaining / left).round,
             bytes.zero? ? 0 : (100.0 * list.sum { |result| result.structure.to_i } / bytes).round)
    end
    private_class_method :band_row

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
      structure, packed = redundancy(output)
      Result.new(
        tool: payload['tool_name'], command: label(payload), bytes: output.bytesize,
        saved: output.bytesize - after, claimed: !updated.nil?,
        shape: updated ? nil : shape_of(output), structure: structure, packed: packed,
        input: JSON.generate(payload['tool_input'] || {}).bytesize,
        trimmed: payload.dig('tool_input', 'command').to_s.match?(SELF_TRIMMED)
      )
    end
    private_class_method :replay

    # Whether there is anything in these bytes for a compressor to take, in two
    # numbers that answer different halves of the question.
    #
    # `structure` is bytes sitting in whole lines that repeat, or in a leading
    # run that at least three lines share. Those are the two shapes a rewrite
    # which has to stay readable can actually bank — the grep compressor banks
    # the second one for one kind of prefix, and every generic scheme anyone
    # would write next banks one or the other.
    #
    # `packed` is deflate on the same bytes. It is a ceiling and not a
    # collectable one: its output is not text a model can read. But it is a hard
    # ceiling, and the useful direction is the negative one — where deflate
    # finds nothing, nothing that stays readable will either, and the ranking
    # above is pointing at bytes that are simply irreducible.
    #
    # Both are measured on the bytes as they arrived, which is what a compressor
    # would be handed. On a corpus where the roster already claims a lot the two
    # will read high for work that is already done; the `saved` column is what
    # says whether that happened.
    def self.redundancy(output)
      # Loaded here and not at the top: this file is required by the hook, which
      # runs on every tool call and never replays anything.
      require 'zlib'
      repeated = 0
      once = []
      seen = Hash.new(0)
      output.lines.each do |line|
        key = line.strip
        next if key.size < 5

        seen[key] += 1
        seen[key] > 1 ? repeated += line.bytesize : once << line
      end
      [repeated + prefix_bytes(once), Zlib::Deflate.deflate(output).bytesize]
    end

    # A leading run up to the first separator, which is the shape a header can
    # factor out. Everything past the first occurrence is the saving.
    PREFIX_HEAD = /\A[^\s:|,]{4,}[\s:|,]/

    def self.prefix_bytes(lines)
      groups = Hash.new(0)
      lines.each do |line|
        head = line[PREFIX_HEAD] or next

        groups[head] += 1
      end
      groups.sum { |head, count| count >= 3 ? (count - 1) * head.bytesize : 0 }
    end
    private_class_method :prefix_bytes

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
    # A newline separates a prefix from its command as surely as `&&` does, and
    # it is how the setup is most often written: `cd /repo` on its own line put
    # 371 calls of a real corpus under a bucket called `cd`.
    PREFIX = [/\A(cd|export|source)\s+\S+[ \t]*(&&|;|\n)\s*/,  # a directory, then the real command
              /\A\w+=\S*\s+/,                             # FOO=bar cmd
              # `[A-Z_]+` because `env -u NAME` takes a *value*, and the peel
              # stopped dead on it: `env -u BUNDLE_LOCKFILE BUNDLE_GEMFILE=…
              # bundle exec rspec` ranked 289 calls under a bucket named
              # `BUNDLE_LOCKFILE`. Matching the variable name rather than
              # "whatever follows a flag" is the safe half of that: `env -i
              # bundle exec rspec` must keep its command, and a real command is
              # never a bare all-caps word.
              /\A(env|timeout)\s+(-\S+\s+|\S+=\S*\s+|[A-Z_][A-Z0-9_]*\s+|\d+\s+)*/].freeze

    # Runners whose *second* word names the family. `npm test` and `npm install`
    # print nothing alike and want different compressors, so collapsing them
    # into one `npm` row hides both. The list grew because the ranking is what
    # decides where the next compressor goes, and it was answering `pytest`,
    # `go` and `mix` under a launcher.
    RUNNERS = %w[bundle bin npm npx pnpm yarn cargo ruby rake git gh rails
                 python python3 poetry uv pip pip3 go mix docker kubectl make
                 dotnet composer php artisan node deno mvn gradle].freeze

    # Redirection, pipes and heredoc openers are syntax, not arguments — and a
    # heredoc is why the first line is all this reads: `python3 - <<'PY'` used
    # to label itself with a word from the Python body.
    SYNTAX = /\A[-<>|&;$(){}]/

    def self.label(payload)
      return payload['tool_name'].to_s unless payload['tool_name'] == 'Bash'

      command = payload.dig('tool_input', 'command').to_s.strip
      # Strip first, then take the line. The other order cannot see a `cd` that
      # sits on its own line, and taking the line matters after the strip
      # anyway: a heredoc body is not arguments.
      line = strip_prefix(command).lines.first.to_s.strip
      words = line.split(/\s+/).reject { |word| word.match?(SYNTAX) }
      # A command that is nothing but setup strips to nothing, and a blank row
      # is worse than a row called `cd`.
      words = command.lines.first.to_s.split(/\s+/) if words.empty?
      head = words.first.to_s.split('/').last
      return head unless RUNNERS.include?(head)

      # The *first word that looks like a subcommand*, not the second word.
      # A flag's value survives the syntax filter and lands in the family slot:
      # `git -C /home/was/projetos/swarm status` ranked under a bucket called
      # `git /home/was/projetos/swarm`, and `ruby -e '...'` put 108 calls under
      # `ruby '`. Both name one invocation rather than a family.
      sub = words.drop(1).find { |word| word.match?(SUBCOMMAND) }
      sub ? "#{words.first} #{sub}" : head
    end

    SUBCOMMAND = /\A[a-z][\w:.-]*\z/

    # Repeatedly, because the prefixes stack: `cd X; FOO=1 timeout 60 rspec`.
    # Bounded rather than "until it stops changing": a label is worth a fixed
    # number of passes and never worth a hang on a pathological command.
    MAX_PREFIXES = 4

    def self.strip_prefix(command)
      MAX_PREFIXES.times do
        before = command
        PREFIX.each { |pattern| command = command.sub(pattern, '') }
        return command if command == before
      end
      command
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
