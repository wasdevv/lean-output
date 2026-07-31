# frozen_string_literal: true

RSpec.describe LeanOutput::Budget do
  describe '.fit' do
    let(:text) { "SUMMARY line\n\n#{(1..8).map { |i| "entry #{i} #{'x' * 100}" }.join("\n\n")}\n" }

    it 'returns the same object when the text already fits' do
      expect(described_class.fit(text, 100_000)).to equal(text)
    end

    it 'returns the same object when there is no budget' do
      expect(described_class.fit(text, nil)).to equal(text)
    end

    it 'keeps the summary and whole entries, never a partial one' do
      fitted = described_class.fit(text, 500)

      expect(fitted).to start_with('SUMMARY line')
      expect(fitted.bytesize).to be <= 500
      entries = fitted.scan(/^entry \d+ (x+)$/).flatten
      expect(entries).to all(have_attributes(length: 100))
    end

    it 'reports how many entries it dropped' do
      fitted = described_class.fit(text, 500)

      kept = fitted.scan(/^entry \d/).size
      expect(fitted).to include("[lean-output] #{8 - kept} of 8 entries omitted")
    end

    it 'keeps the summary even when no entry fits' do
      fitted = described_class.fit(text, 120)

      expect(fitted).to start_with('SUMMARY line')
      expect(fitted).to include('8 of 8 entries omitted')
    end

    it 'splits a diff on file boundaries, not on blank lines inside hunks' do
      diff = fixture('git_show_vendored.txt')

      fitted = described_class.fit(diff, 8_000)

      expect(fitted.bytesize).to be <= 8_000
      expect(fitted.scan(/^diff --git /).size).to be >= 1
      # Every retained file keeps its header; nothing is cut mid-hunk.
      expect(fitted.scan(/^diff --git a\/(\S+)/).flatten).to all(be_a(String))
      expect(fitted).to include('entries omitted')
    end

    it 'leaves single-entry text to the clip fallback' do
      single = 'no blank lines here, just one long run of text'
      expect(described_class.fit(single, 10)).to equal(single)
    end
  end

  describe '.clip' do
    let(:text) { (1..200).map { |i| "line #{i}" }.join("\n") }

    it 'returns the same object when the text already fits' do
      expect(described_class.clip(text, 100_000)).to equal(text)
    end

    it 'keeps both ends and drops the middle' do
      clipped = described_class.clip(text, 400)

      expect(clipped).to include('line 1')
      expect(clipped).to include('line 200')
      expect(clipped).not_to include('line 100')
      expect(clipped).to include('omitted from the middle')
    end

    it 'respects the ceiling' do
      expect(described_class.clip(text, 400).bytesize).to be <= 400
    end

    it 'cuts on line boundaries so no half line survives' do
      clipped = described_class.clip(text, 400)
      body = clipped.lines.reject { |line| line.include?('[lean-output]') }

      expect(body.map(&:chomp).reject(&:empty?)).to all(match(/^line \d+$/))
    end

    it 'never returns invalid UTF-8 when the cut lands inside a codepoint' do
      accented = (1..200).map { |i| "linha #{i} — acentuação" }.join("\n")

      clipped = described_class.clip(accented, 400)

      expect(clipped).to be_valid_encoding
    end

    it 'falls back to a head slice when the budget is smaller than the marker' do
      clipped = described_class.clip(text, 40)

      expect(clipped.bytesize).to be <= 40
      expect(clipped).to be_valid_encoding
    end
  end
end
