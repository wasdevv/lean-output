RSpec.describe LeanOutput::Detector do
  let(:rspec_output) { fixture("rspec_failures.txt") }
  let(:rubocop_output) { fixture("rubocop_offenses.txt") }

  it "picks the RSpec compressor for an rspec command with rspec output" do
    compressor = described_class.for("bundle exec rspec spec/models", rspec_output)
    expect(compressor).to eq(LeanOutput::Compressors::Rspec)
  end

  it "picks the RuboCop compressor for a rubocop command with rubocop output" do
    compressor = described_class.for("bundle exec rubocop app/", rubocop_output)
    expect(compressor).to eq(LeanOutput::Compressors::Rubocop)
  end

  it "picks the Brakeman compressor for a brakeman command with brakeman output" do
    compressor = described_class.for("bundle exec brakeman", fixture("brakeman_warnings.txt"))
    expect(compressor).to eq(LeanOutput::Compressors::Brakeman)
  end

  it "returns nil when the command matches but the output does not" do
    expect(described_class.for("bundle exec rspec", "LoadError: cannot load such file")).to be_nil
  end

  it "returns nil when the output matches but the command does not" do
    expect(described_class.for("cat log/test.log", rspec_output)).to be_nil
  end

  it "returns nil when the user already asked for JSON format" do
    expect(described_class.for("rspec --format json spec/", rspec_output)).to be_nil
    expect(described_class.for("rubocop -f json app/", rubocop_output)).to be_nil
  end

  it "returns nil for ambiguous chained commands whose output matches both tools" do
    chained = "bundle exec rspec && bundle exec rubocop"
    both = rspec_output + "\n" + rubocop_output
    expect(described_class.for(chained, both)).to be_nil
  end

  it "handles ANSI-colored output" do
    compressor = described_class.for("bin/rspec", fixture("rspec_failures_ansi.txt"))
    expect(compressor).to eq(LeanOutput::Compressors::Rspec)
  end
end
