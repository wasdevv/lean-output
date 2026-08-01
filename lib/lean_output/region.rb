# frozen_string_literal: true

module LeanOutput
  # The slice of a buffer a compressor owns: from the start of the first line
  # it recognises to the end of the last one.
  #
  # Lines in between count as owned even when nothing matches them — a tool's
  # blank lines, its deprecation warnings and its progress noise are still its
  # own. What matters is the opposite direction: anything *outside* the span was
  # written by another command on the same shell line, and rewriting the whole
  # buffer would delete it without saying so.
  #
  # `core` anchors the span and must only match lines no other tool writes.
  # Growth is for the parts that carry no such marker: rspec's progress dots
  # come *before* anything identifiable, a diff's last hunk trails *after* the
  # last `@@`. Each compressor grows in one direction only, so two of them can
  # never reach for the same unmarked line and deadlock into an overlap.
  module Region
    def self.span(plain, core:, back: nil, forward: nil)
      lines = plain.lines
      first = lines.index { |line| line.match?(core) }
      return nil unless first

      last = grow(lines, lines.rindex { |line| line.match?(core) }, forward, 1)
      first = grow(lines, first, back, -1)

      start = lines[0...first].sum(&:length)
      start...(start + lines[first..last].sum(&:length))
    end

    BLANK = /\A\s*\z/

    # Crossing a blank line to reach one we recognise is fair; stopping on one
    # is a land grab. So blanks are always crossable — no compressor has to
    # spell that out — and any the growth ends on are handed back. `rubocop |
    # tail -3` is the case that needs both: a blank separates its summary from
    # its progress dots, and another separates the dots from whatever ran before.
    def self.grow(lines, index, claim, step)
      return index unless claim

      crossable = Regexp.union(claim, BLANK)
      edge = index
      edge += step while (0...lines.size).cover?(edge + step) && lines[edge + step].match?(crossable)
      edge -= step while edge != index && lines[edge].match?(BLANK) && (0...lines.size).cover?(edge + step)
      edge
    end
  end
end
