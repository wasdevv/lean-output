module LeanOutput
  module Text
    ANSI = /\e\[[0-9;]*[A-Za-z]/

    def self.plain(str)
      str.gsub(ANSI, "")
    end

    def self.human(bytes)
      bytes >= 1024 ? format("%.1fkB", bytes / 1024.0) : "#{bytes}B"
    end

    # Byte-slicing splits multi-byte codepoints; every clip runs through here so
    # a caller never receives a string that raises on encoding.
    def self.utf8(str)
      str = str.to_s.dup.force_encoding(Encoding::UTF_8)
      str.valid_encoding? ? str : str.scrub("")
    end
  end
end
