RSpec.describe LeanOutput::Compressors::JsonRows do
  describe "a homogeneous row set" do
    let(:original) { fixture("mcp_query_rows.json") }
    subject(:compressed) { described_class.compress(original) }

    it "states the shape of the result" do
      expect(compressed).to include("JSON rows: 40 rows, 7 columns")
    end

    it "emits every column name exactly once" do
      %w[table_schema table_name ordinal_position column_name data_type is_nullable column_default].each do |column|
        expect(compressed.scan(column).size).to eq(1)
      end
    end

    it "keeps every cell value" do
      JSON.parse(original).each do |row|
        row.each_value { |value| expect(compressed).to include(value.nil? ? "null" : value.to_s) }
      end
    end

    it "emits one line per row plus a header and a summary" do
      expect(compressed.lines.size).to eq(42)
    end

    it "distinguishes a SQL NULL from an empty string" do
      expect(compressed).to include("followers_count | integer | NO | 0")
      expect(compressed).to include("user_id | uuid | NO | null")
    end

    it "reduces size by at least 55% on this fixture" do
      expect(compressed.bytesize).to be < original.bytesize * 0.45
    end
  end

  describe "a result wrapped in an envelope" do
    it "finds the single array and compresses it" do
      compressed = described_class.compress(fixture("mcp_query_wrapped.json"))
      expect(compressed).to include("JSON rows: 40 rows, 7 columns")
    end

    it "returns nil when two arrays make the result set ambiguous" do
      payload = JSON.generate("rows" => [{ "a" => 1 }] * 6, "warnings" => [{ "a" => 2 }] * 6)
      expect(described_class.compress(payload)).to be_nil
    end
  end

  describe "output a table cannot represent" do
    it "returns nil for nested values" do
      expect(described_class.compress(fixture("mcp_query_nested.json"))).to be_nil
    end

    it "returns nil when a value contains a newline" do
      expect(described_class.compress(fixture("mcp_query_multiline.json"))).to be_nil
    end

    it "returns nil for a heterogeneous schema" do
      payload = JSON.generate([{ "a" => 1, "b" => 2 }] * 5 + [{ "a" => 1, "c" => 3 }])
      expect(described_class.compress(payload)).to be_nil
    end

    it "returns nil below the minimum row count" do
      expect(described_class.compress(JSON.generate([{ "a" => 1 }] * 4))).to be_nil
    end
  end

  describe "input that is not a row set" do
    it "returns nil for text that is not JSON" do
      expect(described_class.compress("some random output")).to be_nil
    end

    # JSON.parse succeeds on these, so rescuing ParserError is not enough.
    it "returns nil for JSON scalars and empty containers" do
      ["7", "null", "[]", '""', "{}", '["a", "b"]'].each do |payload|
        expect(described_class.compress(payload)).to be_nil
      end
    end
  end

  describe "detection" do
    it "is never claimed from a shell command" do
      expect(described_class.applicable?("psql -c 'select 1' --json", fixture("mcp_query_rows.json"))).to be false
    end

    it "is the only compressor that matches a row set" do
      expect(LeanOutput::Detector.by_output(fixture("mcp_query_rows.json"))).to eq(described_class)
    end
  end
end
