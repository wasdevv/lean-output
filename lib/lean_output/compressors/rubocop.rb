# frozen_string_literal: true

module LeanOutput
  module Compressors
    class Rubocop
      extend Spannable

      COMMAND = Shell.word('rubocop')
      SUMMARY = /^\d+ files? inspected.*$/
      OFFENSE = /^(\S+):(\d+:\d+): \w+: (?:\[Correctable\] )?(.*)$/

      CORE = Regexp.union(/^Inspecting \d+ files?$/, /^Offenses:$/, OFFENSE, SUMMARY)

      # "Inspecting N files" usually anchors the span ahead of the dots, but a
      # `rubocop | tail -3` cuts it off and leaves them stranded. The alphabet
      # is rspec's too; that is safe because both grow backwards only, and a
      # progress line always sits *below* the output of whatever ran before it,
      # never below its own tool's summary.
      PROGRESS = /^[.CWEF]{3,}$/

      def self.back_claim
        PROGRESS
      end

      def self.command_match?(command)
        command.match?(COMMAND)
      end

      def self.output_match?(output)
        Text.plain(output).match?(SUMMARY)
      end

      def self.applicable?(command, output)
        command_match?(command) && output_match?(output)
      end

      def self.summary(plain)
        summary = plain[SUMMARY] or return nil

        out = +"RuboCop: #{summary}"
        plain.scan(OFFENSE).group_by(&:first).each do |file, offenses|
          out << "\n\n#{file}"
          offenses.group_by { |(_, _, message)| message }.each do |message, group|
            locations = group.map { |(_, location, _)| location }
            out << "\n  #{locations.join(', ')} #{message}"
          end
        end

        out << "\n"
      end
    end
  end
end
