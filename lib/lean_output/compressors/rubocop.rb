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
          offenses.group_by { |(_, _, message)| message }.each do |message, group|
            locations = group.map { |(_, location, _)| location }
            out << "\n  #{locations.join(", ")} #{message}"
          end
        end

        out << "\n"
      end
    end
  end
end
