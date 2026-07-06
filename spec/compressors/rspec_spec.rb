RSpec.describe LeanOutput::Compressors::Rspec do
  describe "a suite with failures" do
    let(:original) { fixture("rspec_failures.txt") }
    subject(:compressed) { described_class.compress(original) }

    it "keeps the summary counts and timing" do
      expect(compressed).to include("106 examples, 3 failures")
      expect(compressed).to include("Finished in 2 seconds")
    end

    it "keeps every failure description" do
      expect(compressed).to include("LeanOutput fixture fails on expectation mismatch")
      expect(compressed).to include("LeanOutput fixture raises through gem frames")
      expect(compressed).to include("LeanOutput fixture fails with a long diff")
    end

    it "keeps the Failure/Error source line" do
      expect(compressed).to include('expect(user.email_address).to eq("other@y.com")')
    end

    it "keeps expectation messages" do
      expect(compressed).to include('expected: "other@y.com"')
      expect(compressed).to include('got: "x@y.com"')
    end

    it "keeps exception class and message" do
      expect(compressed).to include("ActiveRecord::RecordNotFound")
      expect(compressed).to include("Couldn't find User with 'id'=-1")
    end

    it "keeps the failing spec file:line of every failure (rerun locations)" do
      expect(compressed).to include("./spec/lean_output_fixture_tmp_spec.rb:4")
      expect(compressed).to include("./spec/lean_output_fixture_tmp_spec.rb:9")
      expect(compressed).to include("./spec/lean_output_fixture_tmp_spec.rb:13")
    end

    it "keeps the first project frame of each failure" do
      expect(compressed).to include("./spec/lean_output_fixture_tmp_spec.rb:6")
    end

    it "drops progress dots, profile, seed and coverage noise" do
      expect(compressed).not_to include("Top 10 slowest")
      expect(compressed).not_to include("slowest example groups")
      expect(compressed).not_to include("Randomized with seed")
      expect(compressed).not_to include("Coverage report")
      expect(compressed).not_to match(/^\.{10,}/)
    end

    it "drops secondary support frames and diff blocks" do
      expect(compressed).not_to include("./spec/support/vcr.rb")
      expect(compressed).not_to include("Diff:")
      expect(compressed).not_to include("(compared using ==)")
    end

    it "reduces size by at least 65% on this fixture" do
      expect(compressed.bytesize).to be < original.bytesize * 0.35
    end
  end

  describe "a passing suite" do
    let(:original) { fixture("rspec_passing.txt") }
    subject(:compressed) { described_class.compress(original) }

    it "collapses to the summary" do
      expect(compressed).to include("102 examples, 0 failures")
      expect(compressed).to include("Finished in 1.89 seconds")
      expect(compressed).not_to include("Top 10 slowest")
      expect(compressed.lines.count).to be <= 3
    end
  end

  describe "ANSI-colored output" do
    it "parses and emits plain text" do
      compressed = described_class.compress(fixture("rspec_failures_ansi.txt"))
      expect(compressed).to include("106 examples, 3 failures")
      expect(compressed).not_to include("\e[")
    end
  end

  describe "unrecognizable output" do
    it "returns nil when there is no summary line (truncated output)" do
      expect(described_class.compress("....\n\nFailures:\n\n  1) something")).to be_nil
    end
  end
end
