# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

# The rungs that keep state from growing forever, and the two gates that were
# loose enough to act on the wrong thing.
RSpec.describe 'housekeeping' do
  around do |example|
    Dir.mktmpdir('housekeeping') do |dir|
      previous = ENV.fetch('LEAN_OUTPUT_STATE_DIR', nil)
      ENV['LEAN_OUTPUT_STATE_DIR'] = dir
      example.run(@dir = dir)
      ENV['LEAN_OUTPUT_STATE_DIR'] = previous
    end
  end

  describe LeanOutput::Session do
    def session(id)
      described_class.load({ 'session_id' => id })
    end

    # Measured on a real cache before this existed: 53 session files going back
    # four weeks. A session id never comes back, so the moment its host process
    # ends the file is dead weight nothing will read again.
    it 'drops session state that has gone past the keep window' do
      session('old').save
      stale = described_class.path('old')
      moment = Time.now.utc - ((described_class::KEEP_DAYS + 1) * 86_400)
      File.utime(moment, moment, stale)

      session('fresh').save

      expect(File.exist?(stale)).to be(false)
      expect(File.exist?(described_class.path('fresh'))).to be(true)
    end

    it 'keeps state that is merely idle' do
      session('yesterday').save
      moment = Time.now.utc - 86_400
      File.utime(moment, moment, described_class.path('yesterday'))

      session('fresh').save

      expect(File.exist?(described_class.path('yesterday'))).to be(true)
    end
  end

  describe LeanOutput::Detector do
    let(:failures) { File.read('spec/fixtures/rspec_failures.txt') }

    # The flag has to be a flag and the value has to be the format. Unanchored,
    # any filename starting with `j` disabled every compressor on the buffer.
    it 'stands aside for output that really is JSON' do
      expect(described_class.for('bundle exec rspec --format json', failures)).to be_empty
      expect(described_class.for('bundle exec rspec -f j', failures)).to be_empty
    end

    # `grep -f <file>` reads patterns from a file. Unanchored, the file's name
    # was being read as a format flag's value.
    it 'no longer bails on a filename that happens to start with j' do
      hits = File.read('spec/fixtures/grep_hits.txt')

      expect(described_class.for('grep -rn -f jargon.txt app/', hits)).not_to be_empty
    end

    # `--format junit` is XML. Bailing on it left cargo output unclaimed for a
    # reason that was not true of the output.
    it 'no longer bails on a format that is not json' do
      cargo = File.read('spec/fixtures/cargo_errors.txt')

      expect(described_class.for('cargo test --format junit', cargo)).not_to be_empty
    end
  end

  describe LeanOutput::ScanCache do
    it 'returns the memo while the file is unchanged and recomputes once it moves' do
      file = File.join(@dir, 'transcript.jsonl')
      File.write(file, "one\n")
      calls = 0
      compute = -> { calls += 1 and [{ 'n' => calls }] }

      described_class.fetch('spec', file, &compute)
      described_class.fetch('spec', file, &compute)
      expect(calls).to eq(1)

      File.write(file, "one\ntwo\n")
      described_class.fetch('spec', file, &compute)
      expect(calls).to eq(2)
    end

    # `clear` is what `lean rescan` calls, and it reported failure while doing
    # nothing after a formatter removed the require it depended on. A rescue
    # that turns a NameError into `false` is exactly the shape that needs a
    # test saying the happy path actually happened.
    it 'really removes the memo and says so' do
      file = File.join(@dir, 'transcript.jsonl')
      File.write(file, "one\n")
      described_class.fetch('spec', file) { [{ 'n' => 1 }] }
      expect(Dir.glob(File.join(@dir, 'scan', '*.json'))).not_to be_empty

      expect(described_class.clear).to be(true)
      expect(Dir.glob(File.join(@dir, 'scan', '*.json'))).to be_empty
    end

    # Every failure mode is a miss, because a miss is the answer the caller
    # wanted anyway — only slower.
    it 'recomputes rather than raising when the memo is damaged' do
      file = File.join(@dir, 'transcript.jsonl')
      File.write(file, "one\n")
      described_class.fetch('spec', file) { [{ 'n' => 1 }] }
      Dir.glob(File.join(@dir, 'scan', '*.json')).each { |memo| File.write(memo, 'not json') }

      expect(described_class.fetch('spec', file) { [{ 'n' => 2 }] }).to eq([{ 'n' => 2 }])
    end
  end

  describe LeanOutput::Corpus do
    it 'names a tool it has no compressor for instead of ranking it as unclaimable' do
      results = [described_class::Result.new(tool: 'Bash', command: 'pytest', bytes: 9_000,
                                             saved: 0, claimed: false, shape: 'pytest')]

      expect(described_class.report(results)).to include('no compressor here', 'pytest')
    end

    it 'says nothing when the roster already covers what ran' do
      results = [described_class::Result.new(tool: 'Bash', command: 'ls', bytes: 900,
                                             saved: 0, claimed: false, shape: nil)]

      expect(described_class.report(results)).not_to include('no compressor here')
    end
  end

  describe LeanOutput::Readback do
    def read_of(path, ranged: false)
      input = { 'file_path' => path }
      input['offset'] = 40 if ranged
      { 'message' => { 'content' => [{ 'type' => 'tool_use', 'name' => 'Read', 'input' => input }] } }
    end

    def spilled(path, notice)
      { 'message' => { 'content' => [{ 'type' => 'tool_result',
                                       'content' => "head\n[lean-output] middle withheld — 40.0kB, " \
                                                    "90 lines, full text at #{path} #{notice}\n" }] } }
    end

    def turn(prefix) = { 'message' => { 'usage' => { 'cache_read_input_tokens' => prefix } } }

    def transcript(records)
      dir = File.join(@dir, 'proj')
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'session.jsonl'), records.map { |r| JSON.generate(r) }.join("\n"))
      described_class.collect(root: @dir)
    end

    let(:vault) { '/home/x/.cache/lean-output/vault/ab/0001-cat.txt' }

    # The rate is a property of the wording, so a reworded pointer starts a new
    # population. Averaged in, a fresh notice would be invisible under months of
    # the old one — which is the experiment, not a detail of it.
    it 'keeps the two notice wordings apart' do
      spills = transcript([turn(1), spilled(vault, '(Read or grep it)'), turn(2),
                           spilled("#{vault}2", '(grep or Read a range)'), turn(3)])

      expect(spills.map(&:notice)).to contain_exactly(described_class::LEGACY, described_class::STEERED)
    end

    # Measured before the rewording: 1054 of 1060 read-backs took the whole
    # file. A pointer followed that way hands everything back and spends a turn.
    it 'counts a read-back that took a range apart from one that took the file' do
      whole = transcript([turn(1), spilled(vault, '(Read or grep it)'), turn(2), read_of(vault), turn(3)])
      expect(whole.first.ranged).to be(false)

      ranged = transcript([turn(1), spilled(vault, '(Read or grep it)'), turn(2),
                           read_of(vault, ranged: true), turn(3)])
      expect(ranged.first.ranged).to be(true)
    end

    it 'leaves ranged unanswered for a pointer nobody followed' do
      expect(transcript([turn(1), spilled(vault, '(Read or grep it)'), turn(2)]).first.ranged).to be_nil
    end
  end

  describe LeanOutput::Calibration do
    it 'keeps every calibration so drift can be told from noise' do
      cwd = File.join(@dir, 'repo')
      2.times do |i|
        described_class.write(cwd, described_class::Result.new(spill: 3_000 * (i + 1), net: 1, spills: 40,
                                                               roundtrips: 2, measured_at: '2026-09-03'))
      end

      expect(described_class.trend(cwd).size).to eq(2)
      expect(described_class.trend(cwd).last).to include('5.9kB')
    end
  end

  describe "#{LeanOutput::Corpus}.compare" do
    # The memo is keyed by file, so a comparison across levels would have handed
    # `full` whatever `volatile` computed — the one question this command exists
    # to answer, answered wrong and silently.
    it 'does not serve one level the answer another level computed' do
      dir = File.join(@dir, 'proj')
      FileUtils.mkdir_p(dir)
      long = (1..400).map { |i| "line #{i} of something no compressor will ever claim #{i * 977}" }.join("\n")
      records = [{ 'sessionId' => 'a', 'cwd' => @dir,
                   'message' => { 'content' => [{ 'type' => 'tool_use', 'id' => 't1', 'name' => 'Bash',
                                                  'input' => { 'command' => 'cat big.log' } }] } },
                 { 'sessionId' => 'a', 'cwd' => @dir,
                   'toolUseResult' => { 'stdout' => long, 'stderr' => '', 'interrupted' => false,
                                        'isImage' => false },
                   'message' => { 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => 't1' }] } }]
      File.write(File.join(dir, 's.jsonl'), records.map { |r| JSON.generate(r) }.join("\n"))

      rows = LeanOutput::Corpus.compare(root: @dir).to_h { |level, _, saved, _, _| [level, saved] }

      expect(rows['volatile']).to be_positive
      expect(rows['safe']).to be_zero
    end
  end

  describe LeanOutput::Usage do
    def transcript(records)
      dir = File.join(@dir, 'proj')
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 's.jsonl'), records.map { |r| JSON.generate(r) }.join("\n"))
    end

    def call_and_result(id, command, stdout)
      [{ 'sessionId' => 'a', 'cwd' => @dir,
         'message' => { 'content' => [{ 'type' => 'tool_use', 'id' => id, 'name' => 'Bash',
                                        'input' => { 'command' => command } }] } },
       { 'sessionId' => 'a', 'cwd' => @dir,
         'toolUseResult' => { 'stdout' => stdout, 'stderr' => '', 'interrupted' => false, 'isImage' => false },
         'message' => { 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => id }] } }]
    end

    def said(text)
      { 'sessionId' => 'a', 'message' => { 'content' => [{ 'type' => 'text', 'text' => text }] } }
    end

    let(:body) { (1..40).map { |i| "app/services/widget_#{i}.rb:#{i}: something long enough" }.join("\n") }

    it 'counts a result the model quoted from as referenced' do
      transcript([*call_and_result('t1', 'grep -rn x app/', body), said('app/services/widget_7.rb'),
                  said('done'), said('more'), said('and more')])

      expect(described_class.scan(root: @dir).map(&:referenced)).to eq([true])
    end

    it 'counts a result nothing ever came back to as unreferenced' do
      transcript([*call_and_result('t1', 'grep -rn x app/', body), said('unrelated prose'),
                  said('still unrelated'), said('nothing matching'), said('nor here')])

      expect(described_class.scan(root: @dir).map(&:referenced)).to eq([false])
    end

    # The caveat is the feature: deciding without quoting reads as unreferenced,
    # so the report has to say so rather than present the number as a verdict.
    it 'says out loud that referenced is not the same as used' do
      rows = [described_class::Row.new(command: 'grep', bytes: 9_000, referenced: false)]

      expect(described_class.report(rows)).to include('not a verdict')
    end
  end

  describe LeanOutput::Profile do
    around do |example|
      ENV['LEAN_OUTPUT_PROFILE'] = '1'
      example.run
      ENV.delete('LEAN_OUTPUT_PROFILE')
    end

    it 'records nothing unless asked' do
      ENV.delete('LEAN_OUTPUT_PROFILE')
      described_class.record(0.05)

      expect(described_class.samples).to be_empty
    end

    # A mean hides the slow call, and the slow call is the one the user feels.
    it 'reports the tail and not just the middle' do
      ([0.001] * 99 + [0.5]).each { |seconds| described_class.record(seconds) }

      report = described_class.report

      expect(report).to include('p99', 'max 500.0ms')
      expect(report).to include('every tool call')
    end

    it 'says so plainly when nothing has been timed' do
      expect(described_class.report).to include('LEAN_OUTPUT_PROFILE=1')
    end
  end

  describe 'the library path' do
    # The scoreboard reads session state written by the hook, so a caller using
    # the gem directly saved bytes that appeared in no total anywhere.
    it 'bills a named caller so its savings are visible to the scoreboard' do
      LeanOutput.compress(File.read('spec/fixtures/rspec_failures.txt'),
                          command: 'bundle exec rspec', credit: 'qa-gate')

      billed = LeanOutput::Session.load({ 'session_id' => 'lib-qa-gate' })

      expect(billed.data.dig('gain', 'calls')).to eq(1)
      expect(billed.data.dig('gain', 'after')).to be < billed.data.dig('gain', 'before')
    end

    it 'bills nothing when no caller asked to be billed' do
      LeanOutput.compress('short', command: 'ls')

      expect(Dir.glob(File.join(@dir, 'lib-*.json'))).to be_empty
    end
  end

  describe LeanOutput::Input do
    def transcript(commands)
      dir = File.join(@dir, 'proj')
      FileUtils.mkdir_p(dir)
      records = commands.each_with_index.flat_map do |command, i|
        [{ 'sessionId' => 'a', 'cwd' => @dir,
           'message' => { 'content' => [{ 'type' => 'tool_use', 'id' => "t#{i}", 'name' => 'Bash',
                                          'input' => { 'command' => command } }] } },
         { 'sessionId' => 'a', 'cwd' => @dir,
           'toolUseResult' => { 'stdout' => 'ok', 'stderr' => '', 'interrupted' => false, 'isImage' => false },
           'message' => { 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => "t#{i}" }] } }]
      end
      File.write(File.join(dir, 's.jsonl'), records.map { |r| JSON.generate(r) }.join("\n"))
    end

    def script(tail)
      "cd /repo && python3 - <<'PY'\n#{'x = 1\n' * 200}print(#{tail})\nPY"
    end

    # The asking side is 55% of what tool calls cost and no rung reaches it.
    it 'counts what the model spent asking, not only what came back' do
      transcript([script(1)])

      row = described_class.scan(root: @dir).find { |r| r.tool == 'Bash' }

      expect(row.input).to be > 1_000
      expect(row.output).to eq(2)
    end

    # A script pasted once is the work. The second paste is the same script
    # charged again, and that is the only pattern on this side with a fix.
    it 'names a script pasted more than once and prices the repeats' do
      transcript([script(1), script(2), script(3)])

      family = described_class.scripts(root: @dir).first

      expect(family.calls).to eq(3)
      expect(family.avoidable).to be_within(200).of(family.bytes / 3 * 2)
    end

    it 'says nothing about a script pasted once' do
      transcript([script(1)])

      expect(described_class.scripts(root: @dir)).to be_empty
    end

    it 'reports rather than promising a rewrite' do
      expect(described_class.report([described_class::Row.new(tool: 'Bash', calls: 1, input: 10, output: 5)]))
        .to include('Nothing here can be rewritten')
    end
  end
end
