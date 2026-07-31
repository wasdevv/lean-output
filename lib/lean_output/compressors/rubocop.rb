module LeanOutput
  module Compressors
    class Rubocop
      COMMAND = %r{(^|[\s/])rubocop(\s|$)}
      SUMMARY = /^\d+ files? inspected.*$/

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      def self.output_match?(output)
        Text.plain(output).match?(SUMMARY)
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
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
