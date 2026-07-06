module LeanOutput
  module Compressors
    class Rubocop
      COMMAND = %r{(^|[\s/])rubocop(\s|$)}
      SUMMARY = /^\d+ files? inspected.*$/

      def self.applicable?(command, output)
        command.match?(COMMAND) && Text.plain(output).match?(SUMMARY)
      end

      def self.compress(output)
        nil
      end
    end
  end
end
