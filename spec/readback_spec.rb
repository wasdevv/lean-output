# frozen_string_literal: true

require 'json'

RSpec.describe LeanOutput::Readback do
  # A transcript is jsonl of records; the two this cares about are an assistant
  # turn (which carries the prefix it re-read) and a tool_result (which may
  # carry a spill notice). Built by hand rather than captured, because the
  # point is the pairing logic, and a captured transcript would pin the test to
  # one session's shape.
  def transcript(dir, name, records)
    path = File.join(dir, 'proj')
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "#{name}.jsonl"), records.map { |r| JSON.generate(r) }.join("\n"))
  end

  def turn(prefix) = { 'message' => { 'usage' => { 'cache_read_input_tokens' => prefix } } }

  def spilled(path, size)
    { 'message' => { 'content' => [{ 'type' => 'tool_result',
                                     'content' => "head\n[lean-output] middle withheld — #{size}, 90 lines, " \
                                                  "full text at #{path} (Read or grep it)\n" }] } }
  end

  def read(path)
    { 'message' => { 'content' => [{ 'type' => 'tool_use', 'name' => 'Read',
                                     'input' => { 'file_path' => path } }] } }
  end

  let(:vault) { '/home/x/.cache/lean-output/vault/ab/0001-cat.txt' }

  around do |example|
    Dir.mktmpdir('readback') { |dir| example.run(@dir = dir) }
  end

  it 'pairs a spill with the read that followed it' do
    transcript(@dir, 's', [turn(1000), spilled(vault, '40.0kB'), turn(50_000), read(vault), turn(60_000)])

    spill = described_class.collect(root: @dir).first

    expect(spill.read_back).to be(true)
    expect(spill.bytes).to eq(40 * 1024)
    expect(spill.prefix).to eq(50_000)
  end

  # The whole point of a pointer is the case where it is the last word, and
  # that case has to be distinguishable from the other one.
  it 'records a pointer nobody followed as not read back' do
    transcript(@dir, 's', [turn(1000), spilled(vault, '40.0kB'), turn(2000), turn(3000)])

    spill = described_class.collect(root: @dir).first

    expect(spill.read_back).to be(false)
    expect(spill.prefix).to be_zero
  end

  # A result spilled early is carried for the rest of the session; one spilled
  # at the end is not. Pricing both the same is what made the delivery-side
  # number wrong in the first place.
  it 'counts the turns the result still had left to be carried' do
    transcript(@dir, 'early', [turn(1), spilled(vault, '40.0kB'), turn(2), turn(3), turn(4)])

    expect(described_class.collect(root: @dir).first.remaining).to eq(3)
  end

  it 'reads the terse notice as well as the explaining one' do
    terse = { 'message' => { 'content' => [{ 'type' => 'tool_result',
                                             'content' => "[lean-output] withheld 8.0kB, 9 lines, " \
                                                          "full text at #{vault}\n" }] } }
    transcript(@dir, 's', [turn(1000), terse, turn(2000)])

    expect(described_class.collect(root: @dir).map(&:bytes)).to eq([8192])
  end

  describe '.net' do
    def spill(bytes:, remaining:, read_back:, prefix: 0)
      described_class::Spill.new(bytes: bytes, remaining: remaining, read_back: read_back, prefix: prefix)
    end

    it 'counts a followed pointer as the turn it cost, not the bytes it withheld' do
      followed = [spill(bytes: 40_000, remaining: 100, read_back: true, prefix: 120_000)]

      expect(described_class.net(followed, 1_000)).to be_negative
    end

    it 'counts an unfollowed pointer as the bytes it withheld for every turn left' do
      missed = [spill(bytes: 40_000, remaining: 100, read_back: false)]

      expect(described_class.net(missed, 1_000)).to be > 900_000
    end

    it 'ignores everything under the floor being tested' do
      expect(described_class.net([spill(bytes: 900, remaining: 100, read_back: true)], 1_000)).to be_zero
    end
  end
end
