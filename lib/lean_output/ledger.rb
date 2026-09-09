# frozen_string_literal: true

require 'digest'

module LeanOutput
  # The two rungs above every compressor in this repo.
  #
  # A compressor answers "what is the shortest text that still carries this
  # signal". That is a good question, and it is the seventh one. Before it sit
  # two cheaper ones, borrowed from ponytail's ladder: does this output need to
  # reach the model at all, and does the model already have it? Bytes the
  # context already holds cost the same as bytes it never needed — and no
  # compressor can win against not sending them.
  #
  # Both rungs are the same test. "Nothing changed since last time" and "you
  # already have this" are one comparison, which is why this is one mechanism
  # instead of the per-tool compressors for `cat`, `ls` and `git status` it
  # replaces. It also reaches Read, which no compressor here can touch: there is
  # no noise in a source file to throw away, only the fact that it was already
  # sent.
  module Ledger
    # How far back a reference may point, measured in tool-output bytes that
    # have gone by since. This is the ceiling that matters and it deserves to be
    # named: the risk is not that the reference is wrong — an identical digest
    # cannot lie about the bytes — but that the occurrence it points at was
    # summarised away by a context compaction, leaving the model holding a
    # pointer into nothing.
    #
    # Bytes rather than a count of tool calls, because forty Reads of a 200-line
    # file and forty `git status` runs push very different amounts of history
    # out of the window. 250kB is roughly 60k tokens of tool output, well inside
    # a context that has not compacted yet. Lower it if you work in sessions
    # that compact often; the bench prints the sensitivity curve.
    WINDOW_BYTES = 250_000

    # A dangling pointer is still recoverable if it says what it pointed at, so
    # the reference carries the head of the result rather than being a bare
    # digest. Two lines is enough to recognise a file or a command's output and
    # cheap enough not to matter against the kilobytes withheld.
    HEAD_LINES = 2
    HEAD_WIDTH = 120

    def self.digest(output)
      Digest::SHA256.hexdigest(output)[0, 16]
    end

    # nil means "not a repeat, or too old to point at" — in both cases the
    # caller carries on to the compressors, which is the safe direction.
    def self.reference(session, output, window: window_bytes)
      previous = session.lookup(digest(output)) or return nil
      distance = session.bytes - previous[:bytes].to_i
      return nil if distance > window

      kind = delivery(previous, output) or return nil
      # The entry was written after its own call advanced the counter, and this
      # call has not advanced it yet, so the immediately preceding call sits at a
      # difference of zero. +1 makes the reference say "1 tool call back".
      calls = session.seq - previous[:seq].to_i + 1
      text = marker(previous, calls, output, kind)
      # The head exists so a pointer whose target fell out of the window is
      # still recognisable. A summary reference does not point at these raw
      # bytes — the model never had them — so quoting two lines of them would
      # spend bytes showing it something new.
      text = "#{text}\n#{head(output)}" unless kind == :summary
      return nil if kind == :summary && text.bytesize >= previous[:size].to_i

      text
    end

    # What the earlier occurrence actually put in front of the model. There are
    # three answers, not two, and the third is the one this rung used to get
    # wrong by not having a name for it:
    #
    #   :verbatim — the bytes reached the model whole, so they are in the
    #     window and "withheld" is a true claim about them;
    #   :spilled  — they did not, and a file holds what the model did not get;
    #   :summary  — a compressor claimed them. The model got a distillation,
    #     nothing went to disk, and there is no raw text anywhere to withhold
    #     or to fetch. The distillation itself is still in the window though,
    #     and pointing at *that* is both true and cheaper than making it again.
    #
    # `nil` is a pointer into nothing: the one case is a path the vault has
    # since evicted. The file check belongs here because a path is the one
    # pointer that can outlive what it names — the vault drops whole session
    # directories past SESSIONS and whole files past KEEP, and neither touches
    # the `seen` entry quoting the path, while a repeat refreshes that entry's
    # recency without writing a file.
    #
    # :summary used to return nil with the others, which sent the result back
    # down the ladder for the same compressor to claim it again and deliver the
    # same distilled failures a second time: measured on rspec_failures.txt,
    # 966B against the ~180B the reference costs. That difference is paid on
    # every repeated test run, at every level — the vault never takes these,
    # because a compressor claimed them.
    def self.delivery(previous, output)
      return File.exist?(previous[:path]) ? :spilled : nil if previous[:path]
      return :verbatim if previous[:size].to_i >= output.bytesize

      :summary
    end
    private_class_method :delivery

    # Reached only when `delivery` named a state, so every arm is a true claim.
    # The :summary arm is the one that has to watch its words: nothing was
    # withheld that a reader could go and get, so it says what is actually the
    # case — the shorter text the model was given is above, and this is not it
    # a second time.
    def self.marker(previous, calls, output, kind)
      head = "[lean-output] byte-identical to #{previous[:label]} from #{plural(calls)} back"
      case kind
      when :summary
        "#{head} — its #{Text.human(previous[:size].to_i)} summary is already above, not repeated"
      when :verbatim
        "#{head} — #{sizes(output)} withheld"
      else
        # Worded like the vault's own notice and no longer: this is paid on
        # every repeat of a spilled result, and the two extra facts a longer
        # sentence would add — that the earlier one was a pointer too, and why —
        # change nothing about what the reader does next.
        "#{head} — #{sizes(output)}, full text at #{previous[:path]} (Read or grep it)"
      end
    end
    private_class_method :marker

    def self.sizes(output)
      "#{Text.human(output.bytesize)}, #{output.lines.size} lines"
    end
    private_class_method :sizes

    def self.plural(calls)
      calls == 1 ? '1 tool call' : "#{calls} tool calls"
    end
    private_class_method :plural

    def self.head(output)
      output.lines.first(HEAD_LINES).map { |line| "  #{line.chomp[0, HEAD_WIDTH]}" }.join("\n")
    end
    private_class_method :head

    # What the reference will call this result when a later one points back at
    # it. A path or a command is what the reader recognises; the tool name alone
    # would make two different Reads indistinguishable.
    def self.label(tool, payload)
      case tool
      when 'Read'
        path = payload.dig('tool_input', 'file_path').to_s
        path.empty? ? 'a Read' : "Read #{shorten(path)}"
      when 'Bash'
        command = payload.dig('tool_input', 'command').to_s
        command.empty? ? 'a Bash call' : "`#{shorten(command, 80)}`"
      else
        tool.to_s.delete_prefix('mcp__')
      end
    end

    def self.shorten(text, limit = 60)
      single = text.gsub(/\s+/, ' ').strip
      single.size <= limit ? single : "#{single[0, limit - 1]}…"
    end
    private_class_method :shorten

    def self.window_bytes
      value = ENV['LEAN_OUTPUT_WINDOW'].to_i
      value.positive? ? value : WINDOW_BYTES
    end
  end
end
