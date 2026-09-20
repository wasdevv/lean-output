# frozen_string_literal: true

# What the plugin stops claiming once the host has taken the window away.
#
# Two rungs here say "it is already above": the ledger withholds bytes on that
# promise, and `explain?` stops repeating the spill notice on it. Both were
# guarded only by `WINDOW_BYTES`, a 250kB guess at whether a compaction had
# happened yet. PreCompact turns the guess into an event, so these examples
# assert the difference between the two — a repeat that is well inside the
# window and still must not be answered with a pointer into a summary.
RSpec.describe 'a compaction' do
  def hook(tool, payload)
    LeanOutput::Runner.call({ 'tool_name' => tool, 'session_id' => 'compaction-spec' }.merge(payload))
  end

  def read(path, content)
    hook('Read', 'tool_input' => { 'file_path' => path },
                 'tool_response' => { 'file' => { 'filePath' => path, 'content' => content } })
  end

  def compact
    LeanOutput::Runner.call('hook_event_name' => 'PreCompact', 'session_id' => 'compaction-spec',
                            'trigger' => 'manual')
  end

  def session
    LeanOutput::Session.load('session_id' => 'compaction-spec')
  end

  # Small enough that the vault declines it, so the delivery under test is
  # :verbatim — the one that claims the bytes themselves are still above.
  let(:body) { "line one\nline two\n#{'filler ' * 40}\n" }

  it 'writes nothing to the host' do
    expect(compact).to be_nil
  end

  it 'answers a repeat with a pointer while the window is intact' do
    read('app/models/user.rb', body)

    expect(updated_text(read('app/models/user.rb', body))).to include('byte-identical')
  end

  it 'stops pointing at an occurrence the summary replaced' do
    read('app/models/user.rb', body)
    compact

    expect(read('app/models/user.rb', body)).to be_nil
  end

  it 'still points at an occurrence that came after the cut' do
    compact
    read('app/models/user.rb', body)

    expect(updated_text(read('app/models/user.rb', body))).to include('byte-identical')
  end

  # The vault only runs at `volatile`, which is where the one delivery that
  # outlives a compaction can be observed at all.
  it 'keeps pointing at a spill, whose text is on disk and not in the window' do
    ENV['LEAN_OUTPUT_MODE'] = 'volatile'
    spilled = "spillable\n#{'x' * 40_000}\n"
    expect(updated_text(read('app/models/big.rb', spilled))).to include('full text at')
    compact

    repeat = updated_text(read('app/models/big.rb', spilled))
    expect(repeat).to include('byte-identical', 'full text at')
  end

  it 'records the cut at the bytes seen so far' do
    read('app/models/user.rb', body)
    compact

    expect(session.floor).to eq(session.bytes)
    expect(session.floor).to be_positive
  end

  # Driven through real spills rather than `explain?` directly, because the
  # topic is stamped with the byte clock as it stands *during* the call and the
  # ledger's entries are stamped after it — an example that called the predicate
  # on an untouched session would be comparing two marks the runtime never
  # produces together.
  it 'says the long vault notice again once the earlier one has been summarised away' do
    ENV['LEAN_OUTPUT_MODE'] = 'volatile'
    first = updated_text(read('a.rb', "one\n#{'x' * 40_000}\n"))
    second = updated_text(read('b.rb', "two\n#{'y' * 40_000}\n"))
    expect(first).to include('middle withheld')
    expect(second).to include('withheld')
    expect(second).not_to include('middle withheld')

    compact
    third = updated_text(read('c.rb', "three\n#{'z' * 40_000}\n"))
    expect(third).to include('middle withheld')
  end

  it 'survives a payload the host sends without a session id' do
    expect { LeanOutput::Runner.call('hook_event_name' => 'PreCompact', 'cwd' => Dir.pwd) }.not_to raise_error
  end
end
