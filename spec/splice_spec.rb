# frozen_string_literal: true

RSpec.describe LeanOutput::Splice do
  def rewrite(range, text) = described_class::Rewrite.new(range, text)

  let(:buffer) { "aaa\nbbb\nccc\n" }

  it 'replaces a span and keeps everything around it' do
    result = described_class.apply(buffer, [rewrite(4...8, "B\n")])
    expect(result).to eq("aaa\nB\nccc\n")
  end

  it 'places several spans in buffer order, whatever order they arrive in' do
    late = rewrite(8...12, "C\n")
    early = rewrite(0...4, "A\n")
    expect(described_class.apply(buffer, [late, early])).to eq("A\nbbb\nC\n")
  end

  it 'refuses when two spans overlap' do
    # Two compressors claiming the same bytes disagree about who wrote them, and
    # there is no honest way to pick. That, not the shape of the command, is
    # what ambiguity means here.
    expect(described_class.apply(buffer, [rewrite(0...6, 'A'), rewrite(4...12, 'C')])).to be_nil
  end

  it 'allows two spans that merely touch' do
    result = described_class.apply(buffer, [rewrite(0...4, "A\n"), rewrite(4...12, "C\n")])
    expect(result).to eq("A\nC\n")
  end
end
