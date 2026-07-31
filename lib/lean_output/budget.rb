# frozen_string_literal: true

module LeanOutput
  # Fits text into a byte budget without cutting through a failure.
  #
  # Callers that inject tool output into a prompt always have a hard ceiling and
  # otherwise reach for byteslice, which amputates whatever sits at the cut —
  # usually the very message the reader needed. Both entry points here spend the
  # budget on whole units and say what they dropped.
  module Budget
    # Room reserved for the marker line appended by each strategy.
    MARKER_ROOM = 96

    # Compressor output is a summary followed by repeated entries. Keeps the
    # summary plus as many whole entries as fit.
    def self.fit(text, limit)
      return text if limit.nil? || text.bytesize <= limit

      parts, separator = split_entries(text)
      summary, *entries = parts
      return text if entries.empty?

      used = summary.bytesize + MARKER_ROOM
      kept = entries.take_while { |entry| (used += entry.bytesize + separator.bytesize) <= limit }
      return text if kept.size == entries.size

      omitted = entries.size - kept.size
      [summary, *kept].join(separator) +
        "#{separator}[lean-output] #{omitted} of #{entries.size} entries omitted (budget #{Text.human(limit)})\n"
    end

    # A diff's entries are files, and a blank line inside a hunk is not a
    # boundary — splitting one on blank lines drops whole files while keeping a
    # commit header. Everything else (failures, offenses, diagnostics) is
    # blank-line separated.
    def self.split_entries(text)
      if text.match?(/^diff --git /)
        [text.split(/\n(?=diff --git )/), "\n"]
      else
        [text.split(/\n\n+/), "\n\n"]
      end
    end
    private_class_method :split_entries

    # Last resort for text no compressor understands. Keeps both ends because
    # signal clusters there — the invocation and early errors at the head, the
    # summary and exit status at the tail — and only the middle is dropped.
    def self.clip(text, limit)
      return text if limit.nil? || text.bytesize <= limit

      half = (limit - MARKER_ROOM) / 2
      return Text.utf8(text.byteslice(0, limit)) if half < 1

      head = trim_after_last_newline(Text.utf8(text.byteslice(0, half)))
      tail = trim_before_first_newline(Text.utf8(text.byteslice(text.bytesize - half, half)))
      omitted = text.bytesize - head.bytesize - tail.bytesize

      "#{head}\n[lean-output] #{Text.human(omitted)} omitted from the middle (budget #{Text.human(limit)})\n#{tail}"
    end

    def self.trim_after_last_newline(str)
      index = str.rindex("\n")
      index ? str[0, index] : str
    end

    def self.trim_before_first_newline(str)
      index = str.index("\n")
      index ? str[(index + 1)..] : str
    end
    private_class_method :trim_after_last_newline, :trim_before_first_newline
  end
end
