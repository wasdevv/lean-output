# frozen_string_literal: true

module LeanOutput
  # A compressor states two things: `CORE`, the lines only it writes, and
  # `summary`, the text that should stand in for them. This pairs the two into
  # a rewrite the splicer can place without touching the rest of the buffer.
  module Spannable
    def rewrite(plain)
      range = region(plain) or return nil
      # Summarising the slice rather than the buffer is what keeps a compressor
      # from reporting on text it does not own — a `git show` preamble sitting
      # outside the span would otherwise come back twice.
      text = summary(plain[range]) or return nil

      Splice::Rewrite.new(range, text)
    end

    def region(plain)
      Region.span(plain, core: self::CORE, back: back_claim, forward: forward_claim)
    end

    def back_claim
      nil
    end

    def forward_claim
      nil
    end
  end
end
