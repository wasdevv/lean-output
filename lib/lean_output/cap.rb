# frozen_string_literal: true

module LeanOutput
  # Rung 1: does this output need to exist at all?
  #
  # The compressors ask what the shortest text carrying a signal is, and the
  # ledger asks whether the model already holds it. Both answer after the bytes
  # have been produced. `grep -rn` over a large tree, `find` from a deep root,
  # `cat` of a generated file — those are unbounded by construction, and the
  # cheapest rewrite available is the `head` the caller forgot to type.
  #
  # This is the only rung that changes what *runs*, so it is deliberately the
  # narrowest one here: a fixed roster of read-only listing commands, refused at
  # the first shell metacharacter, and never silent.
  module Cap
    LINES = 200

    # Read-only, line-oriented, and unbounded unless told otherwise. `head`,
    # `tail` and `wc` are absent on purpose: they already carry their own
    # ceiling. `sed` and `awk` are absent because their output shape depends on
    # the script, and a ceiling on an unknown shape is a guess.
    CAPPABLE = %w[grep rg egrep fgrep ls find cat].freeze

    # `git` is not one command, and the roster cannot treat it as one. Measured
    # over 40 real transcripts, `git log` was the largest uncapped subcommand at
    # 69kB across 50 calls and `git status` added 34kB more — neither has a
    # compressor behind it. `git diff` and `git show` do, and a ceiling in front
    # of that compressor would hand it a truncated diff, costing hunks and paths
    # it would otherwise have kept. Capping the binary would have been a net
    # loss on the two subcommands that were already handled.
    CAPPABLE_SUB = { 'git' => %w[log status].freeze }.freeze

    # Refused anywhere in the string, inside quotes or not. Deciding whether a
    # `|` is quoted means parsing the shell, and a parser that is wrong once
    # corrupts a command the user is about to run. Over-refusing costs only a
    # rewrite that was optional to begin with — `grep "foo|bar"` goes through
    # untouched, which is the right way to be wrong here.
    UNSAFE = /[|><;&$`(){}\n]/

    # `cd path && real-command` is the shape most Bash calls take here, and
    # taking the first word blinds the ceiling to every one of them: the command
    # that produces the bytes is the one after the `&&`. Measured over 40 real
    # transcripts, `cd` led every other head word at 293kB across 331 calls,
    # entirely uncapped. corpus.rb already strips this prefix before it
    # classifies, so the two ends disagreed about what the command even was.
    #
    # `\S+` holds it to a single unquoted argument. A path with a space or a
    # quote does not match, falls through, and is refused exactly as before.
    PREFIX = /\A(?:cd|env)\s+\S+\s*&&\s*/

    # A ceiling the caller set already. Anything piped is refused above, so the
    # only survivor is grep's own counter.
    LIMITED = /(?:\A|\s)(?:-m\d*|--max-count)(?:=|\s|\z)/

    NOTICE = "[lean-output] This command was limited to its first #{LINES} lines. " \
             'If the result looks cut off, re-run it narrower rather than assuming it is complete.'.freeze

    # Returned with no `permissionDecision` on purpose. The host runs its whole
    # permission check against the *modified* input, so capping never grants
    # anything: a command the user would have been asked about is still asked
    # about, with the `| head` visible in the prompt. Attaching `allow` here
    # would have made a compression plugin into an auto-approver.
    def self.call(payload)
      return nil unless payload['tool_name'] == 'Bash'

      command = payload.dig('tool_input', 'command').to_s
      capped = rewrite(command, Mode.policy(Mode.resolve(payload['cwd']))) or return nil

      {
        'hookSpecificOutput' => {
          'hookEventName' => 'PreToolUse',
          'updatedInput' => payload['tool_input'].merge('command' => capped),
          # The model has to be told, and it has to be told whether or not the
          # ceiling was actually reached — nothing here can know that yet. So
          # the wording claims a limit, never a truncation: a listing that was
          # cut and says it is whole is worth less than the bytes it saved.
          'additionalContext' => NOTICE
        }
      }
    end

    def self.rewrite(command, policy)
      return nil unless policy && !policy[:lossless_only]

      stripped = command.strip
      prefix, rest = split_prefix(stripped)
      return nil if rest.empty? || rest.match?(UNSAFE) || rest.match?(LIMITED)
      return nil unless cappable?(rest)

      # Appending after a metacharacter-free command cannot land inside a quote
      # or change how the words before it parse. The pipe binds tighter than the
      # `&&`, so it still applies to the command that was classified, not to the
      # `cd` in front of it.
      "#{prefix}#{rest} | head -n #{LINES}"
    end

    # A subcommand is read at a fixed position, so `git -C path log` does not
    # match and is refused. Over-refusing costs a long result; guessing where
    # the subcommand starts costs a ceiling on the wrong command.
    def self.cappable?(command)
      word = head_word(command)
      subs = CAPPABLE_SUB[word] or return CAPPABLE.include?(word)

      subs.include?(command.split(/\s+/)[1].to_s)
    end
    private_class_method :cappable?

    def self.split_prefix(command)
      match = PREFIX.match(command) or return ['', command]

      [match[0], match.post_match]
    end
    private_class_method :split_prefix

    def self.head_word(command)
      command.split(/\s+/).first.to_s.split('/').last
    end
    private_class_method :head_word
  end
end
