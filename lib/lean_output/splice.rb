# frozen_string_literal: true

module LeanOutput
  # Replaces each compressor's span with its summary and leaves the rest of the
  # buffer alone. This is what makes `bin/rails db:prepare && rspec` safe: the
  # migration output sits outside every span, so it survives verbatim.
  #
  # Two spans that overlap is the one case with no honest answer — the tools
  # disagree about who wrote those bytes. That, and not the shape of the
  # command, is what ambiguity means here, so it ends in passthrough.
  module Splice
    Rewrite = Struct.new(:range, :text)

    def self.apply(plain, rewrites)
      ordered = rewrites.sort_by { |rewrite| rewrite.range.begin }
      return nil if overlapping?(ordered)

      out = +''
      cursor = 0
      ordered.each do |rewrite|
        out << plain[cursor...rewrite.range.begin]
        out << rewrite.text
        cursor = rewrite.range.end
      end
      out << plain[cursor..]
      out
    end

    def self.overlapping?(ordered)
      ordered.each_cons(2).any? { |before, after| before.range.end > after.range.begin }
    end
  end
end
