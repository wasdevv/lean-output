RSpec.describe LeanOutput::Compressors::Rubocop do
  describe "a run with offenses" do
    let(:original) { fixture("rubocop_offenses.txt") }
    subject(:compressed) { described_class.compress(original) }

    it "keeps the summary" do
      expect(compressed).to include("18 files inspected, 13 offenses detected, 13 offenses autocorrectable")
    end

    it "keeps every offense location (line:col)" do
      %w[2:24 2:26 4:16 4:18 4:19 5:11 5:16 5:23 9:11 11:13 11:21 15:16 17:4].each do |loc|
        expect(compressed).to include(loc)
      end
    end

    it "keeps cop names and messages" do
      expect(compressed).to include("Layout/SpaceInsideParens: Space inside parentheses detected.")
      expect(compressed).to include("Style/RedundantReturn: Redundant return detected.")
    end

    it "groups offenses by file instead of repeating the path" do
      expect(compressed.scan("app/models/lean_output_bad_tmp.rb").size).to eq(1)
    end

    it "dedupes repeated cop/message pairs, listing all locations once" do
      expect(compressed.scan("Layout/TrailingWhitespace").size).to eq(1)
      expect(compressed).to include("11:21, 15:16, 17:4 Layout/TrailingWhitespace")
    end

    it "drops code excerpts, carets and progress noise" do
      expect(compressed).not_to include("^^^")
      expect(compressed).not_to include("Inspecting 18 files")
      expect(compressed).not_to include("[Correctable]")
      expect(compressed).not_to include("return x")
    end

    it "reduces size by at least 65% on this fixture" do
      expect(compressed.bytesize).to be < original.bytesize * 0.35
    end
  end

  describe "a clean run" do
    it "collapses to the summary" do
      compressed = described_class.compress(fixture("rubocop_clean.txt"))
      expect(compressed).to include("no offenses detected")
      expect(compressed.lines.count).to be <= 2
    end
  end

  describe "ANSI-colored output" do
    it "parses and emits plain text" do
      compressed = described_class.compress(fixture("rubocop_offenses_ansi.txt"))
      expect(compressed).to include("13 offenses detected")
      expect(compressed).not_to include("\e[")
    end
  end

  describe "unrecognizable output" do
    it "returns nil without a summary line" do
      expect(described_class.compress("some random output")).to be_nil
    end
  end
end
