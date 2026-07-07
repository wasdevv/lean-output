module LeanOutput
  class Detector
    COMPRESSORS = [Compressors::Rspec, Compressors::Rubocop, Compressors::Brakeman].freeze
    JSON_FORMAT = /(-f|--format)[= ]?j/

    def self.for(command, output)
      return nil if command.match?(JSON_FORMAT)

      matches = COMPRESSORS.select { |compressor| compressor.applicable?(command, output) }
      matches.size == 1 ? matches.first : nil
    end
  end
end
