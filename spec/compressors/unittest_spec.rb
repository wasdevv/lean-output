# frozen_string_literal: true

require 'spec_helper'

# Fixtures captured from `python3 -m unittest -v`. When an assertion here
# disagrees with them, the suspicion is the code.
RSpec.describe LeanOutput::Compressors::Unittest do
  let(:failures) { File.read('spec/fixtures/unittest_failures.txt') }
  let(:passing) { File.read('spec/fixtures/unittest_passing.txt') }

  def compress(text, command: 'python3 -m unittest -v')
    LeanOutput.compress(text, command: command)
  end

  it 'keeps both a FAIL and an ERROR with the message that explains them' do
    result = compress(failures)

    expect(result).to include('ERROR: test_raises', 'FAIL: test_compare')
    expect(result).to include('ValueError: boom', "AssertionError: 'x@y.com' != 'other@y.com'")
  end

  # The diff under an assertEqual is the failure, not decoration. An earlier
  # span ended above it and the splicer glued it onto the line before.
  it 'keeps the diff that follows the assertion message' do
    expect(compress(failures)).to include('- x@y.com', '+ other@y.com')
  end

  # Every compressor here emits the same `file:line` shape, so one grep finds a
  # location whatever tool produced it.
  it 'turns a traceback frame into the file:line shape the rest of the plugin uses' do
    expect(compress(failures)).to match(/test_thing\.py:7 in test_raises/)
  end

  it 'keeps the verdict in the runner’s own words' do
    result = compress(failures)

    expect(result).to include('Ran 5 tests', 'FAILED (failures=1, errors=1, skipped=1)')
  end

  it 'drops the per-case lines, which are the bulk of any real suite' do
    result = compress(failures)

    expect(result).not_to include('test_passes (test_thing.ThingTest) ... ok')
    expect(result).not_to include('Traceback (most recent call last)')
  end

  it 'reduces a green run to its verdict' do
    expect(compress(passing)).to eq("Ran 3 tests in 0.000s\nOK")
  end

  describe 'what it refuses' do
    it 'stands aside without a command naming unittest' do
      expect(described_class.applicable?('bundle exec rspec', failures)).to be(false)
    end

    # `Ran N tests` is the line no other tool prints, so a buffer that merely
    # contains `... ok` is not this runner's.
    it 'stands aside for output with no runner tail' do
      expect(described_class.output_match?("something (a.B) ... ok\n")).to be(false)
    end

    it 'leaves what another command on the same line printed' do
      chained = "#{failures}\nline 40 of the file\n"

      expect(compress(chained, command: 'python3 -m unittest -v; cat notes.txt'))
        .to include('line 40 of the file')
    end
  end
end
