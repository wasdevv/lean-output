# frozen_string_literal: true

module LeanOutput
  module Text
    ANSI = /\e\[[0-9;]*[A-Za-z]/

    def self.plain(str)
      str.gsub(ANSI, '')
    end

    def self.human(bytes)
      bytes >= 1024 ? format('%.1fkB', bytes / 1024.0) : "#{bytes}B"
    end

    # Head and tail, never the middle: a long result states its subject at the
    # top and its verdict at the bottom, and the part that repeats is between
    # them. nil when the text already fits, so a caller can tell "left alone"
    # from "clipped to exactly the cap".
    def self.clip(str, cap, tail: 0.25)
      return nil if cap.nil? || str.bytesize <= cap

      back = (cap * tail).to_i
      "#{utf8(str.byteslice(0, cap - back))}\n…\n#{utf8(str.byteslice(-back, back))}"
    end

    # Byte-slicing splits multi-byte codepoints; every clip runs through here so
    # a caller never receives a string that raises on encoding.
    def self.utf8(str)
      str = str.to_s.dup.force_encoding(Encoding::UTF_8)
      str.valid_encoding? ? str : str.scrub('')
    end
  end
end
