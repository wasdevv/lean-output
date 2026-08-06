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
    def self.reference(session, output, _label, window: window_bytes)
      previous = session.lookup(digest(output)) or return nil
      distance = session.bytes - previous[:bytes].to_i
      return nil if distance > window

      # The entry was written after its own call advanced the counter, and this
      # call has not advanced it yet, so the immediately preceding call sits at a
      # difference of zero. +1 makes the reference say "1 tool call back".
      calls = session.seq - previous[:seq].to_i + 1
      "#{marker(previous, calls, output)}\n#{head(output)}"
    end

    def self.marker(previous, calls, output)
      "[lean-output] byte-identical to #{previous[:label]} from #{plural(calls)} back — " \
        "#{Text.human(output.bytesize)}, #{output.lines.size} lines withheld"
    end
    private_class_method :marker

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
