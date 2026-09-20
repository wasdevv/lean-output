# frozen_string_literal: true

# The pass that reaches the tool call.
#
# Every example here is about something being taken out of the window, so every
# example is also about what must survive it: a result never outlives its call,
# a failure is never dropped, and no user or assistant text is ever rewritten.
RSpec.describe LeanOutput::Compaction do
  # Enough filler to push the pairs under test out of the pinned window at both
  # ends, built as plain assistant turns so nothing in it is a candidate.
  def filler(count) = Array.new(count) { |i| { 'role' => 'assistant', 'text' => "step #{i}" } }

  def call(id, tool, input, text, **extra)
    [{ 'role' => 'assistant', 'text' => '', 'toolUses' => [{ 'tool_use_id' => id, 'tool' => tool, 'input' => input }] },
     { 'role' => 'user', 'text' => '', 'toolResults' => [{ 'tool_use_id' => id, 'text' => text }.merge(extra)] }]
  end

  def transcript(*middle)
    [{ 'role' => 'user', 'text' => 'the task' }] + middle + filler(LeanOutput::Compaction::PINNED_RECENT)
  end

  def ids(messages)
    messages.flat_map { |m| (m['toolUses'] || []).map { |u| u['tool_use_id'] } }
  end

  def results(messages)
    messages.flat_map { |m| (m['toolResults'] || []) }
  end

  it 'declines a transcript with nothing to take out' do
    expect(described_class.prune(transcript(*call('a', 'Read', { 'file_path' => 'x.rb' }, 'body')))).to be_nil
  end

  it 'declines anything that is not a list of messages' do
    expect(described_class.prune(nil)).to be_nil
    expect(described_class.prune('messages')).to be_nil
  end

  describe 'an identical call made again later' do
    let(:input) { { 'file_path' => 'app/models/user.rb' } }
    let(:messages) do
      transcript(*call('old', 'Read', input, 'the old body'),
                 *filler(2),
                 *call('new', 'Read', input, 'the new body'))
    end

    it 'drops the older pair whole — call and result together' do
      pruned = described_class.prune(messages)

      expect(ids(pruned)).to eq(['new'])
      expect(results(pruned).map { |r| r['tool_use_id'] }).to eq(['new'])
    end

    it 'keeps the newer answer verbatim' do
      expect(results(described_class.prune(messages)).first['text']).to eq('the new body')
    end

    it 'leaves the pair alone when the input differs by one byte' do
      other = transcript(*call('old', 'Read', { 'file_path' => 'app/models/user.rb ' }, 'the old body'),
                         *filler(2),
                         *call('new', 'Read', input, 'the new body'))

      expect(described_class.prune(other)).to be_nil
    end

    it 'leaves the pair alone when the tool differs' do
      other = transcript(*call('old', 'Grep', input, 'the old body'),
                         *filler(2),
                         *call('new', 'Read', input, 'the new body'))

      expect(described_class.prune(other)).to be_nil
    end
  end

  it 'never drops a failure, however often it was retried' do
    messages = transcript(*call('old', 'Bash', { 'command' => 'rspec' }, 'boom', 'isError' => true),
                          *filler(2),
                          *call('new', 'Bash', { 'command' => 'rspec' }, 'boom again', 'isError' => true))
    pruned = described_class.prune(messages)

    expect(pruned).to be_nil
  end

  it 'supersedes an older success with a later failure of the same call' do
    messages = transcript(*call('old', 'Bash', { 'command' => 'rspec' }, 'all green'),
                          *filler(2),
                          *call('new', 'Bash', { 'command' => 'rspec' }, 'boom', 'isError' => true))

    expect(ids(described_class.prune(messages))).to eq(['new'])
  end

  describe 'a result the vault already holds' do
    let(:spilled) do
      "head line\nmore preview\n[lean-output] withheld 40.0kB, 900 lines, full text at %s (grep or Read a range)\n"
    end

    it 'keeps the locator and drops the preview around it' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'spill.txt')
        File.write(path, 'the whole thing')
        messages = transcript(*call('a', 'Read', { 'file_path' => 'big.rb' }, format(spilled, path)), *filler(2))

        text = results(described_class.prune(messages)).first['text']
        expect(text).to include(path)
        expect(text).not_to include('head line')
      end
    end

    it 'keeps the preview when the vault has since evicted the file' do
      messages = transcript(*call('a', 'Read', { 'file_path' => 'big.rb' }, format(spilled, '/gone/spill.txt')),
                            *filler(2))

      expect(described_class.prune(messages)).to be_nil
    end
  end

  it 'replaces a repeat of bytes kept elsewhere with a note' do
    body = "identical\n#{'x' * 500}"
    messages = transcript(*call('a', 'Read', { 'file_path' => 'one.rb' }, body),
                          *filler(2),
                          *call('b', 'Read', { 'file_path' => 'two.rb' }, body))
    pruned = described_class.prune(messages)

    expect(ids(pruned)).to contain_exactly('a', 'b')
    texts = results(pruned).map { |r| r['text'] }
    expect(texts).to include(body)
    expect(texts).to include(LeanOutput::Compaction::REPEAT)
  end

  describe 'what it refuses to touch' do
    let(:input) { { 'file_path' => 'x.rb' } }

    it 'leaves a call still waiting for its result' do
      messages = transcript(
        { 'role' => 'assistant', 'text' => '',
          'toolUses' => [{ 'tool_use_id' => 'orphan', 'tool' => 'Read', 'input' => input }] },
        *filler(2), *call('new', 'Read', input, 'body')
      )

      expect(ids(described_class.prune(messages) || messages)).to include('orphan')
    end

    it 'leaves a result whose call is missing' do
      messages = transcript(
        { 'role' => 'user', 'text' => '', 'toolResults' => [{ 'tool_use_id' => 'stray', 'text' => 'body' }] },
        *filler(2), *call('new', 'Read', input, 'body')
      )

      expect(results(described_class.prune(messages) || messages).map { |r| r['tool_use_id'] }).to include('stray')
    end

    it 'leaves a tool_use_id that appears twice' do
      messages = transcript(*call('dup', 'Read', input, 'first'),
                            *call('dup', 'Read', input, 'second'),
                            *filler(2))

      expect(described_class.prune(messages)).to be_nil
    end

    it 'leaves the first message and the recent window' do
      messages = transcript(*call('old', 'Read', input, 'body'), *filler(2), *call('new', 'Read', input, 'body'))
      pruned = described_class.prune(messages)

      expect(pruned.first).to eq('role' => 'user', 'text' => 'the task')
      expect(pruned.last(described_class::PINNED_RECENT)).to eq(messages.last(described_class::PINNED_RECENT))
    end
  end

  it 'never rewrites user or assistant text' do
    input = { 'file_path' => 'x.rb' }
    prose = { 'role' => 'assistant', 'text' => "I will read it.\n\nThen edit." }
    messages = transcript(*call('old', 'Read', input, 'body'), prose, *filler(2), *call('new', 'Read', input, 'body'))

    texts = described_class.prune(messages).map { |m| m['text'] }
    expect(texts).to include("I will read it.\n\nThen edit.", 'the task')
  end

  it 'hands back untouched messages as the same objects, and changed ones without their handle' do
    input = { 'file_path' => 'x.rb' }
    messages = transcript(*call('old', 'Read', input, 'body'), *filler(2), *call('new', 'Read', input, 'body'))
    messages.each_with_index { |message, i| message['handle'] = "h#{i}" }
    pruned = described_class.prune(messages)

    untouched = pruned.select { |message| messages.any? { |original| original.equal?(message) } }
    expect(untouched).not_to be_empty
    changed = pruned - untouched
    expect(changed).to all(satisfy { |message| !message.key?('handle') })
  end

  it 'removes a message a dropped pair left with nothing in it' do
    input = { 'file_path' => 'x.rb' }
    messages = transcript(*call('old', 'Read', input, 'body'), *filler(2), *call('new', 'Read', input, 'body'))

    expect(described_class.prune(messages).size).to eq(messages.size - 2)
  end

  it 'never returns an empty transcript' do
    input = { 'file_path' => 'x.rb' }
    messages = transcript(*call('old', 'Read', input, 'body'), *filler(2), *call('new', 'Read', input, 'body'))

    expect(described_class.prune(messages)).not_to be_empty
  end
end

# The fourth rule, and the one that moves the bytes: a call's payload goes to
# the vault and the call keeps its head and a locator. Every example here is
# about the same trade — the window gets shorter, the disk keeps everything.
RSpec.describe LeanOutput::Compaction, 'on the call side' do
  def session(dir)
    ENV['LEAN_OUTPUT_STATE_DIR'] = dir
    LeanOutput::Session.load('session_id' => 'call-spec')
  end

  def pair(id, tool, input, text = 'ok')
    [{ 'role' => 'assistant', 'text' => '',
       'toolUses' => [{ 'tool_use_id' => id, 'tool' => tool, 'input' => input }] },
     { 'role' => 'user', 'text' => '', 'toolResults' => [{ 'tool_use_id' => id, 'text' => text }] }]
  end

  def transcript(*middle)
    [{ 'role' => 'user', 'text' => 'the task' }] + middle +
      Array.new(LeanOutput::Compaction::PINNED_RECENT) { { 'role' => 'assistant', 'text' => 'tail' } }
  end

  def uses(messages) = messages.flat_map { |m| m['toolUses'] || [] }

  let(:script) { "python3 - <<'PY'\n#{'# a long generated line\n' * 80}PY" }

  it 'puts a bulky command on disk and leaves a locator behind' do
    Dir.mktmpdir do |dir|
      messages = transcript(*pair('toolu_a1', 'Bash', { 'command' => script }))
      pruned = described_class.prune(messages, session(dir))

      command = uses(pruned).first['input']['command']
      expect(command.bytesize).to be < script.bytesize
      expect(command).to start_with("python3 - <<'PY'")
      expect(command).to include('full text at')
    end
  end

  it 'stores the original bytes, exactly' do
    Dir.mktmpdir do |dir|
      messages = transcript(*pair('toolu_a1', 'Bash', { 'command' => script }))
      pruned = described_class.prune(messages, session(dir))

      path = uses(pruned).first['input']['command'][/full text at (\S+)/, 1]
      expect(File.read(path)).to eq(script)
    end
  end

  it 'leaves a command under the floor alone' do
    Dir.mktmpdir do |dir|
      messages = transcript(*pair('toolu_a1', 'Bash', { 'command' => 'bundle exec rspec' }))

      expect(described_class.prune(messages, session(dir))).to be_nil
    end
  end

  it 'rewrites only the payload field, never the rest of the input' do
    Dir.mktmpdir do |dir|
      input = { 'file_path' => 'gen.py', 'content' => 'X' * 3000 }
      pruned = described_class.prune(transcript(*pair('toolu_b2', 'Write', input)), session(dir))

      written = uses(pruned).first['input']
      expect(written['file_path']).to eq('gen.py')
      expect(written['content']).to include('full text at')
    end
  end

  it 'does not spill a call that is being dropped anyway' do
    Dir.mktmpdir do |dir|
      input = { 'command' => script }
      messages = transcript(*pair('toolu_old', 'Bash', input),
                            { 'role' => 'assistant', 'text' => 'mid' },
                            *pair('toolu_new', 'Bash', input))
      pruned = described_class.prune(messages, session(dir))

      expect(uses(pruned).map { |u| u['tool_use_id'] }).to eq(['toolu_new'])
      expect(Dir.glob(File.join(dir, 'vault', '**', '*.txt')).size).to eq(1)
    end
  end

  it 'leaves the pinned window whole, however bulky its calls are' do
    Dir.mktmpdir do |dir|
      # The pair has to land inside the last PINNED_RECENT messages, which means
      # putting the filler *before* it — the first arrangement of this example
      # put the pair in the free range and passed for the wrong reason.
      filler = Array.new(LeanOutput::Compaction::PINNED_RECENT - 2) { { 'role' => 'assistant', 'text' => 't' } }
      messages = [{ 'role' => 'user', 'text' => 'the task' }] + filler +
                 pair('toolu_r', 'Bash', { 'command' => script })
      expect(messages.size - LeanOutput::Compaction::PINNED_RECENT).to eq(1)

      expect(described_class.prune(messages, session(dir))).to be_nil
    end
  end

  it 'keeps the call whole when no session was given, and still runs the other rules' do
    input = { 'file_path' => 'x.rb' }
    messages = transcript(*pair('toolu_old', 'Read', input, 'body'),
                          { 'role' => 'assistant', 'text' => 'mid' },
                          *pair('toolu_new', 'Read', input, 'body'))
    pruned = described_class.prune(messages)

    expect(uses(pruned).map { |u| u['tool_use_id'] }).to eq(['toolu_new'])
  end

  it 'keeps the call whole when the disk refuses' do
    Dir.mktmpdir do |dir|
      live = session(dir)
      allow(LeanOutput::Vault).to receive(:store).and_return(nil)
      messages = transcript(*pair('toolu_a1', 'Bash', { 'command' => script }))

      expect(described_class.prune(messages, live)).to be_nil
    end
  end

  it 'honours a floor set in the environment' do
    Dir.mktmpdir do |dir|
      previous = ENV.fetch('LEAN_OUTPUT_CALL_FLOOR', nil)
      ENV['LEAN_OUTPUT_CALL_FLOOR'] = '10'
      messages = transcript(*pair('toolu_a1', 'Bash', { 'command' => 'bundle exec rspec --format doc' }))

      expect(described_class.prune(messages, session(dir))).not_to be_nil
    ensure
      ENV['LEAN_OUTPUT_CALL_FLOOR'] = previous
    end
  end
end

# The measurement, which exists because "the rules reach enough" is a claim
# with a number behind it or it is not a claim. These examples hold the
# accounting, not the number: the number is whatever this machine's transcripts
# say, and `lean compaction` is how you read it.
RSpec.describe 'the compaction survey' do
  def transcript(dir, *lines)
    file = File.join(dir, 'p', "#{lines.object_id}.jsonl")
    LeanOutput::Session.mkdir_p(File.dirname(file))
    File.write(file, lines.map { |line| "#{JSON.generate(line)}\n" }.join)
    file
  end

  def use(id, tool, input)
    { 'type' => 'assistant', 'message' => { 'content' => [{ 'type' => 'tool_use', 'id' => id,
                                                            'name' => tool, 'input' => input }] } }
  end

  def result(id, text)
    { 'type' => 'user', 'message' => { 'content' => [{ 'type' => 'tool_result', 'tool_use_id' => id,
                                                       'content' => text }] } }
  end

  def prose(text) = { 'type' => 'assistant', 'message' => { 'content' => [{ 'type' => 'text', 'text' => text }] } }

  it 'counts a superseded pair against the surface it could reach' do
    Dir.mktmpdir do |dir|
      input = { 'file_path' => 'x.rb' }
      lines = [prose('start'), use('a', 'Read', input), result('a', 'old'), prose('mid'),
               use('b', 'Read', input), result('b', 'new')] + Array.new(6) { prose('tail') }
      transcript(dir, *lines)

      survey = LeanOutput::Compaction.survey(root: dir)
      expect(survey.files).to eq(1)
      expect(survey.pairs).to eq(2)
      expect(survey.superseded).to eq(1)
      expect(survey.caught).to eq(1)
    end
  end

  it 'counts a pair no rule reached as the residue a classifier would have to earn' do
    Dir.mktmpdir do |dir|
      lines = [prose('start'), use('a', 'Read', { 'file_path' => 'lonely.rb' }), result('a', 'x' * 900)] +
              Array.new(6) { prose('tail') }
      transcript(dir, *lines)

      survey = LeanOutput::Compaction.survey(root: dir)
      expect(survey.caught).to eq(0)
      expect(survey.residue).to eq(1)
      expect(survey.residue_bytes).to eq(900)
      expect(survey.reach).to eq(0.0)
    end
  end

  it 'reports a corpus it found nothing in rather than dividing by it' do
    Dir.mktmpdir { |dir| expect(LeanOutput::Compaction.report(LeanOutput::Compaction.survey(root: dir))).to eq('no transcripts found') }
  end

  it 'skips a line it cannot parse instead of losing the transcript' do
    Dir.mktmpdir do |dir|
      input = { 'file_path' => 'x.rb' }
      file = transcript(dir, prose('start'), use('a', 'Read', input), result('a', 'old'),
                        use('b', 'Read', input), result('b', 'new'), *Array.new(6) { prose('tail') })
      File.write(file, "not json\n", mode: 'a')

      expect(LeanOutput::Compaction.survey(root: dir).superseded).to eq(1)
    end
  end
end
