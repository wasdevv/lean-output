# frozen_string_literal: true

require 'json'

module LeanOutput
  # The half of the bill this plugin cannot touch, so that at least it can be
  # seen.
  #
  # Every number in this repo measures tool *output*. The *input* — the command
  # in a Bash call, the whole file body in a Write, the old and new strings in
  # an Edit — is written by the model into its own turn, and it sits in the
  # context window under exactly the same arithmetic: paid once per turn that
  # remains in the session.
  #
  # Measured over a real corpus: **13.15MB of input against 10.64MB of output**.
  # The input is 124% of the thing this plugin was built to shrink, and 55% of
  # what tool calls cost in total. `Write` alone is 3.46MB against effectively
  # zero output; `Edit` is 2.18MB against 0.02MB.
  #
  # **None of it is reachable from a PostToolUse hook**, and that is not a gap
  # to be closed later: the tokens are spent when the model emits the tool_use
  # block, and nothing downstream can retract a message already in the
  # conversation. So this reports and never rewrites — the whole point is to
  # say where the money goes on the side no rung can reach, because the lever
  # there is what the agent is asked to do, not how its output is written.
  module Input
    DEFAULT_ROOT = Corpus::DEFAULT_ROOT

    Row = Struct.new(:tool, :calls, :input, :output, keyword_init: true)

    def self.scan(root: DEFAULT_ROOT, since: nil, project: nil)
      totals = Hash.new { |hash, key| hash[key] = Row.new(tool: key, calls: 0, input: 0, output: 0) }
      Corpus.transcripts(root, since: since, project: project).each do |file|
        ScanCache.fetch('input', file) { from_session(file) }.each do |row|
          into = totals[row['tool']]
          into.calls += row['calls']
          into.input += row['input']
          into.output += row['output']
        end
      end
      totals.values.sort_by { |row| -row.input }
    end

    def self.from_session(file)
      totals = Hash.new { |hash, key| hash[key] = { 'tool' => key, 'calls' => 0, 'input' => 0, 'output' => 0 } }
      calls = {}
      File.foreach(file) do |line|
        record = Corpus.send(:parse, line) or next
        Corpus.send(:harvest, record, calls) do |payload|
          row = totals[payload['tool_name'].to_s]
          row['calls'] += 1
          row['input'] += JSON.generate(payload['tool_input'] || {}).bytesize
          row['output'] += Runner.extract_output(payload['tool_response']).to_s.bytesize
        end
      end
      totals.values
    rescue StandardError
      []
    end
    private_class_method :from_session

    def self.report(rows, limit: 8)
      return 'no tool calls found — is the transcript root right?' if rows.empty?

      input = rows.sum(&:input)
      output = rows.sum(&:output)
      [format('%-16s %8s %11s %11s', 'tool', 'calls', 'input MB', 'output MB'),
       *rows.first(limit).map do |row|
         format('%-16s %8d %10.2f %11.2f', row.tool, row.calls, mb(row.input), mb(row.output))
       end,
       '',
       format('input %.2fMB against output %.2fMB — the asking side is %d%% of the bill',
              mb(input), mb(output), (100.0 * input / (input + output)).round),
       'Nothing here can be rewritten: the tokens are spent when the model emits the call.',
       'What moves this number is what the agent is asked to do, not how output is written.'].join("\n")
    end

    # The one pattern on this side with a fix, and the only reason this file is
    # more than a lament.
    #
    # A heredoc pastes a whole script into the turn. Pasted once that is the
    # work; pasted with small variations it is the same script charged again
    # every time, and measured over a real corpus that is where the input mass
    # sits: heredocs are 67% of all Bash input, and of the ones over 1kB,
    # **60% is the second and later paste of a script already in the window** —
    # 2.14MB, 16% of every byte the model spends asking for anything. One
    # family in that corpus is a 2kB Python script pasted 128 times.
    #
    # The fix is not a rung. Nothing here can un-send a paste, and a PreToolUse
    # hook cannot either — the bytes are in the turn before it runs, and the
    # only decision channel that survives `bypassPermissions` is `deny`, which
    # is not a thing to spend on byte economy. What removes this is a
    # convention — write the script to a file once, run it by path — and what
    # this does is put a number on it before and a number on it after.
    MIN_SCRIPT = 1_000
    HEREDOC = /<<-?['"]?\w+/
    # A path plus arguments, which is what the second run costs instead.
    PATH_COST = 60

    Family = Struct.new(:head, :calls, :bytes, :avoidable, keyword_init: true)

    def self.scripts(root: DEFAULT_ROOT, since: nil, project: nil)
      groups = Hash.new { |hash, key| hash[key] = [] }
      Corpus.transcripts(root, since: since, project: project).each do |file|
        ScanCache.fetch('scripts', file) { pastes(file) }.each do |row|
          groups[[file, row['head']]] << row['bytes']
        end
      end
      families(groups)
    end

    def self.pastes(file)
      rows = []
      calls = {}
      File.foreach(file) do |line|
        record = Corpus.send(:parse, line) or next
        Corpus.send(:harvest, record, calls) do |payload|
          command = payload.dig('tool_input', 'command').to_s
          next unless command.bytesize > MIN_SCRIPT && command.match?(HEREDOC)

          rows << { 'head' => command.gsub(/\s+/, ' ')[0, 60], 'bytes' => command.bytesize }
        end
      end
      rows
    rescue StandardError
      []
    end
    private_class_method :pastes

    # Only a family — the same script shape more than once in one session — has
    # anything to save. A script pasted once is the work being done.
    def self.families(groups)
      groups.filter_map do |(_, head), sizes|
        next if sizes.size < 2

        Family.new(head: head, calls: sizes.size, bytes: sizes.sum,
                   avoidable: sizes.drop(1).sum - ((sizes.size - 1) * PATH_COST))
      end.sort_by { |family| -family.avoidable }
    end
    private_class_method :families

    def self.scripts_report(families, limit: 6)
      return 'no repeated heredocs — nothing here to change' if families.empty?

      total = families.sum(&:avoidable)
      [format('%d families of a script pasted more than once in one session', families.size),
       format('%.2fMB would not have been sent if each were written to a file once and run by path',
              mb(total)),
       '',
       format('%6s %10s %10s  %s', 'pastes', 'MB', 'avoidable', 'starts with'),
       *families.first(limit).map do |family|
         format('%6d %9.2f %10.2f  %s', family.calls, mb(family.bytes), mb(family.avoidable),
                family.head[0, 58])
       end].join("\n")
    end

    def self.mb(bytes) = bytes / 1024.0 / 1024
    private_class_method :mb
  end
end
