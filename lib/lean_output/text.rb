module LeanOutput
  module Text
    ANSI = /\e\[[0-9;]*[A-Za-z]/

    def self.plain(str)
      str.gsub(ANSI, "")
    end
  end
end
