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

      separator, summary, entries = *split_entries(text)
      return text if entries.empty?

      used = summary.bytesize + MARKER_ROOM
      kept = entries.take_while { |entry| (used += entry.bytesize + separator.bytesize) <= limit }
      return text if kept.size == entries.size

      [summary, *kept].join(separator) +
        "#{separator}[lean-output] #{entries.size - kept.size} of #{entries.size} " \
        "entries omitted (budget #{Text.human(limit)})\n"
    end

    # A diff's entries are files, and a blank line inside a hunk is not a
    # boundary — splitting one on blank lines drops whole files while keeping a
    # commit header. Everything else (failures, offenses, diagnostics) is
    # blank-line separated.
    def self.split_entries(text)
      separator = text.match?(/^diff --git /) ? "\n" : "\n\n"
      summary, *entries = text.split(separator == "\n" ? /\n(?=diff --git )/ : /\n\n+/)

      [separator, summary, entries]
    end
    private_class_method :split_entries

    # Last resort for text no compressor understands. Keeps both ends because
    # signal clusters there — the invocation and early errors at the head, the
    # summary and exit status at the tail — and only the middle is dropped.
    # Distinct from `Text.clip`, which is the hook's ceiling: that one spends a
    # fraction of its cap on the tail and returns nil when the text already
    # fits. This one splits the budget evenly, is exact about the ceiling
    # because a caller injecting into a prompt has no slack, and returns the
    # text either way. Two callers, two contracts — merging them costs two
    # parameters and buys four lines.
    def self.clip(text, limit)
      return text if limit.nil? || text.bytesize <= limit

      half = (limit - MARKER_ROOM) / 2
      return Text.utf8(text.byteslice(0, limit)) if half < 1

      head = trim_head(Text.utf8(text.byteslice(0, half)))
      tail = trim_tail(Text.utf8(text.byteslice(text.bytesize - half, half)))
      omitted = text.bytesize - head.bytesize - tail.bytesize

      "#{head}\n[lean-output] #{Text.human(omitted)} omitted from the middle (budget #{Text.human(limit)})\n#{tail}"
    end

    # Cut on a line boundary when there is one. `rpartition`/`partition` would
    # say this in one expression each and return "" for a slice with no newline
    # at all — a minified file, one long row — dropping the very content the
    # budget was spent on rather than leaving a ragged edge.
    def self.trim_head(str) = str[0, str.rindex("\n") || str.length]
    def self.trim_tail(str) = str[(str.index("\n")&.succ || 0)..]
    private_class_method :trim_head, :trim_tail
  end
end
