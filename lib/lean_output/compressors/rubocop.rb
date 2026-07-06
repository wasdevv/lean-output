module LeanOutput
  module Compressors
    class Rubocop
      COMMAND = %r{(^|[\s/])rubocop(\s|$)}
      SUMMARY = /^\d+ files? inspected.*$/

      def self.applicable?(command, output)
        command.match?(COMMAND) && Text.plain(output).match?(SUMMARY)
      end

      OFFENSE = /^(\S+):(\d+:\d+): \w+: (?:\[Correctable\] )?(.*)$/

      def self.compress(output)
        plain = Text.plain(output)
        summary = plain[SUMMARY] or return nil

        out = +"RuboCop: #{summary}"
        plain.scan(OFFENSE).group_by(&:first).each do |file, offenses|
          out << "\n\n#{file}"
          offenses.each { |(_, location, message)| out << "\n  #{location} #{message}" }
        end

        out << "\n"
      end
    end
  end
end
