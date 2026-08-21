# frozen_string_literal: true

RSpec.describe LeanOutput::Ledger do
  # Drives the real Runner rather than the module in isolation: the ordering it
  # depends on — reference before advance, remember after — lives there, and a
  # unit test of `reference` alone would keep passing if that order flipped.
  def hook(tool, payload)
    LeanOutput::Runner.call({ 'tool_name' => tool, 'session_id' => 'ledger-spec' }.merge(payload))
  end

  def read(path, content)
    hook('Read', 'tool_input' => { 'file_path' => path },
                 'tool_response' => { 'file' => { 'filePath' => path, 'content' => content } })
  end

  def updated(result)
    updated_text(result)
  end

  let(:body) { "line one\nline two\n#{'filler ' * 200}\n" }

  it 'says nothing about a result it is seeing for the first time' do
    expect(read('app/models/user.rb', body)).to be_nil
  end

  it 'points the second occurrence back at the first' do
    read('app/models/user.rb', body)
    text = updated(read('app/models/user.rb', body))

    expect(text).to include('byte-identical to Read app/models/user.rb')
    expect(text).to include('1 tool call back')
  end

  it 'counts the calls in between' do
    read('app/models/user.rb', body)
    read('app/models/post.rb', "#{body}other")
    read('app/models/tag.rb', "#{body}another")
    text = updated(read('app/models/user.rb', body))

    expect(text).to include('3 tool calls back')
  end

  it 'refuses to match on anything but the exact bytes' do
    read('app/models/user.rb', body)

    expect(read('app/models/user.rb', "#{body} ")).to be_nil
  end

  it 'points back even when the same bytes arrive under a different path' do
    read('app/models/user.rb', body)
    text = updated(read('vendor/copy.rb', body))

    expect(text).to include('byte-identical to Read app/models/user.rb')
  end

  it 'keeps a chain of repeats alive by refreshing the entry each time' do
    read('app/models/user.rb', body)
    2.times { read('app/models/user.rb', body) }
    text = updated(read('app/models/user.rb', body))

    expect(text).to include('1 tool call back')
  end

  it 'stops pointing once the occurrence has fallen out of the window' do
    read('app/models/user.rb', body)
    read('app/models/post.rb', 'x' * 5_000)

    expect(described_class.reference(session_after, body, window: 100)).to be_nil
  end

  it 'still points when the window is wide enough to reach' do
    read('app/models/user.rb', body)
    read('app/models/post.rb', 'x' * 5_000)

    expect(described_class.reference(session_after, body, window: 100_000)).to include('byte-identical')
  end

  it 'ignores a result too small for the reference to be worth its own bytes' do
    tiny = "ok\n"
    read('app/models/user.rb', tiny)

    expect(read('app/models/user.rb', tiny)).to be_nil
  end

  describe 'what the reference carries' do
    it 'names the size and line count it withheld' do
      read('app/models/user.rb', body)
      text = updated(read('app/models/user.rb', body))

      expect(text).to include(LeanOutput::Text.human(body.bytesize))
      expect(text).to include("#{body.lines.size} lines withheld")
    end

    it 'shows the head so a pointer into nothing is still recoverable' do
      read('app/models/user.rb', body)
      text = updated(read('app/models/user.rb', body))

      expect(text).to include('  line one')
      expect(text).to include('  line two')
    end

    it 'costs a small fraction of what it replaces' do
      read('app/models/user.rb', body)
      text = updated(read('app/models/user.rb', body))

      expect(text.bytesize).to be < body.bytesize * 0.3
    end
  end

  # The half of the invariant the vault fix missed. A compressor claims the
  # result, it fits under the ceiling, so nothing reaches the vault and nothing
  # reaches disk — and the model holds a distilled summary, not the raw lines.
  # Saying "100 lines withheld" there is the same lie the vault case made, minus
  # even the file to recover from, and it is the common case: this is the path
  # `full`, the shipped default, takes on every repeated test run.
  describe 'a repeat of something the model only ever saw compressed' do
    let(:failures) { fixture('rspec_failures.txt') }

    def rspec_run
      LeanOutput::Runner.call(
        'tool_name' => 'Bash', 'session_id' => 'compressed-repeat',
        'tool_input' => { 'command' => 'bundle exec rspec' },
        'tool_response' => { 'stdout' => failures, 'stderr' => '' }
      )&.dig('hookSpecificOutput', 'updatedToolOutput', 'stdout')
    end

    it 'delivers the summary again rather than claiming the lines are withheld' do
      first = rspec_run
      second = rspec_run

      expect(second).not_to include('withheld')
      expect(second).to include('rspec ./')
      expect(second.bytesize).to eq(first.bytesize)
    end

    # The saving is real, so declining has to stay narrow: a result that reached
    # the model verbatim is still deduplicated, and that is the case the ledger
    # was built for.
    it 'still references a repeat that was delivered verbatim' do
      read('app/models/user.rb', body)

      expect(updated(read('app/models/user.rb', body))).to include('lines withheld')
    end
  end

  describe '.label' do
    it 'names a Read by its path' do
      expect(described_class.label('Read', 'tool_input' => { 'file_path' => 'a/b.rb' })).to eq('Read a/b.rb')
    end

    it 'names a Bash call by its command' do
      expect(described_class.label('Bash', 'tool_input' => { 'command' => 'git status' })).to eq('`git status`')
    end

    it 'shortens a command that would bury the marker' do
      label = described_class.label('Bash', 'tool_input' => { 'command' => 'a' * 200 })
      expect(label.length).to be <= 82
      expect(label).to end_with('…`')
    end

    it 'collapses a multi-line command onto one line' do
      label = described_class.label('Bash', 'tool_input' => { 'command' => "git \\\n  status" })
      expect(label).to eq('`git \\ status`')
    end

    it 'drops the mcp prefix so the marker reads like a tool name' do
      expect(described_class.label('mcp__insforge__query', {})).to eq('insforge__query')
    end

    it 'falls back to something readable when the input is missing' do
      expect(described_class.label('Read', {})).to eq('a Read')
      expect(described_class.label('Bash', {})).to eq('a Bash call')
    end
  end

  def session_after
    LeanOutput::Session.load('session_id' => 'ledger-spec')
  end
end
