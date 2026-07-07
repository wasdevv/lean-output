RSpec.describe LeanOutput::Compressors::Brakeman do
  describe "a scan with warnings" do
    let(:original) { fixture("brakeman_warnings.txt") }
    subject(:compressed) { described_class.compress(original) }

    it "keeps the warning count" do
      expect(compressed).to include("5 security warnings")
    end

    it "keeps every warning line number" do
      [3, 8, 9, 13, 14].each do |line|
        expect(compressed).to match(/^  #{line} \[/)
      end
    end

    it "keeps confidence, category, message and code" do
      expect(compressed).to include('[High] Command Injection: Possible command injection — system("echo #{params[:cmd]}")')
      expect(compressed).to include("[High] SQL Injection: Possible SQL injection")
    end

    it "groups warnings by file instead of repeating the path" do
      expect(compressed.scan("app/controllers/lean_output_vuln_tmp_controller.rb").size).to eq(1)
    end

    it "drops progress, checks list and report boilerplate" do
      expect(compressed).not_to include("Processing data flow")
      expect(compressed).not_to include("Checks Run")
      expect(compressed).not_to include("== Brakeman Report ==")
      expect(compressed).not_to include("== Warning Types ==")
    end

    it "reduces size by at least 75% on this fixture" do
      expect(compressed.bytesize).to be < original.bytesize * 0.25
    end
  end

  describe "a clean scan" do
    it "collapses to the summary" do
      compressed = described_class.compress(fixture("brakeman_clean.txt"))
      expect(compressed).to include("0 security warnings")
      expect(compressed.lines.count).to be <= 2
    end
  end

  describe "ANSI-colored output" do
    it "parses and emits plain text" do
      compressed = described_class.compress(fixture("brakeman_warnings_ansi.txt"))
      expect(compressed).to include("5 security warnings")
      expect(compressed).not_to include("\e[")
    end
  end

  describe "unrecognizable output" do
    it "returns nil without a report" do
      expect(described_class.compress("some random output")).to be_nil
    end
  end
end
