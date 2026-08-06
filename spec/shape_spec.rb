# frozen_string_literal: true

require 'spec_helper'

# The check that was missing for eight versions.
#
# The host validates `updatedToolOutput` against the tool's own output shape and
# silently keeps the original when it does not match, so a plugin that returns
# the wrong type is not broken in any way a test of its own JSON can see: the
# hook runs, exits 0, prints valid JSON, and nothing happens. Every example here
# therefore asserts against a response shape copied out of a real transcript
# (`toolUseResult`), never one built to match what the code emits.
RSpec.describe 'the replacement mirrors the tool response shape' do
  def compress(payload)
    LeanOutput::Runner.call(payload)&.dig('hookSpecificOutput', 'updatedToolOutput')
  end

  # Verbatim key set of a Bash toolUseResult.
  def bash_payload(stdout, command: 'grep -rn "def " app/')
    {
      'hook_event_name' => 'PostToolUse',
      'session_id' => 'shape-spec',
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => command },
      'tool_response' => {
        'stdout' => stdout, 'stderr' => '', 'interrupted' => false,
        'isImage' => false, 'noOutputExpected' => false
      }
    }
  end

  # Verbatim key set of a Read toolUseResult.
  def read_payload(content, path: 'app/models/user.rb')
    {
      'hook_event_name' => 'PostToolUse',
      'session_id' => 'shape-spec',
      'tool_name' => 'Read',
      'tool_input' => { 'file_path' => path },
      'tool_response' => {
        'type' => 'text',
        'file' => {
          'filePath' => path, 'content' => content,
          'numLines' => content.lines.size, 'startLine' => 1, 'totalLines' => content.lines.size
        }
      }
    }
  end

  def grep_hits
    (1..60).flat_map do |i|
      (1..4).map { |j| "app/services/thing_#{i}.rb:#{j * 7}:  def call_#{j}(argument, keyword: nil)" }
    end.join("\n")
  end

  it 'returns a Hash carrying exactly the keys Bash returned' do
    payload = bash_payload(grep_hits)
    updated = compress(payload)

    expect(updated).to be_a(Hash)
    expect(updated.keys).to match_array(payload['tool_response'].keys)
    expect(updated['stdout'].bytesize).to be < payload['tool_response']['stdout'].bytesize
  end

  it 'preserves the flags Bash set rather than inventing defaults' do
    payload = bash_payload(grep_hits)
    payload['tool_response']['interrupted'] = true
    updated = compress(payload)

    expect(updated['interrupted']).to be(true)
    expect(updated['noOutputExpected']).to be(false)
  end

  # stderr is folded into the text upstream, so leaving the original in place
  # would send those bytes a second time inside the very result meant to shrink.
  it 'empties stderr once it has been folded into the replacement text' do
    payload = bash_payload(grep_hits)
    payload['tool_response']['stderr'] = 'warning: something noisy'
    updated = compress(payload)

    expect(updated['stderr']).to eq('')
    expect(updated['stdout']).to include('warning: something noisy')
  end

  it 'replaces content in place for Read, keeping the file metadata' do
    content = (1..80).map { |i| "  line #{i} of a source file" }.join("\n")
    payload = read_payload(content)

    expect(compress(payload)).to be_nil, 'a first Read has nothing to point back at'

    updated = compress(payload)
    expect(updated).to be_a(Hash)
    expect(updated.keys).to match_array(%w[type file])
    expect(updated['file'].keys).to match_array(payload['tool_response']['file'].keys)
    expect(updated['file']['content']).to include('[lean-output]')
    expect(updated['file']['filePath']).to eq('app/models/user.rb')
  end

  it 'mirrors the content-block array an MCP tool returns' do
    payload = {
      'hook_event_name' => 'PostToolUse', 'session_id' => 'shape-spec',
      'tool_name' => 'mcp__db__query', 'tool_input' => {},
      'tool_response' => [{ 'type' => 'text', 'text' => fixture('mcp_query_rows.json') }]
    }
    updated = compress(payload)

    expect(updated).to be_an(Array)
    expect(updated.first['type']).to eq('text')
    expect(updated.first['text']).to be_a(String)
  end

  # A failure event carries the output in `error` with no tool_response at all,
  # so the only shape there is to mirror is the string that arrived.
  it 'stays a String when the output arrived as a bare error' do
    payload = {
      'hook_event_name' => 'PostToolUseFailure', 'session_id' => 'shape-spec',
      'tool_name' => 'Bash', 'tool_input' => { 'command' => 'bundle exec rspec' },
      'error' => "Exit code 1\n\n#{fixture('rspec_failures.txt')}"
    }

    expect(compress(payload)).to be_a(String)
  end

  it 'passes through a shape it does not recognise instead of guessing at one' do
    payload = bash_payload(grep_hits)
    payload['tool_response'] = { 'somethingNew' => grep_hits }

    expect(compress(payload)).to be_nil
  end

  it 'never touches an image result' do
    payload = bash_payload(grep_hits)
    payload['tool_response']['isImage'] = true

    expect(compress(payload)).to be_nil
  end
end
