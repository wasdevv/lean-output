# frozen_string_literal: true

require 'spec_helper'

# The fixtures are captured from `node --test` on Node 22, not written from
# memory. When an assertion here disagrees with them, the suspicion is the code,
# not the fixture — this repo has already shipped a compressor whose test
# entered through the door the code opened for it rather than the one the tool
# uses.
RSpec.describe LeanOutput::Compressors::NodeTest do
  let(:failures) { File.read('spec/fixtures/node_test_failures.txt') }
  let(:passing) { File.read('spec/fixtures/node_test_passing.txt') }

  def compress(text, command: 'node --test')
    LeanOutput.compress(text, command: command)
  end

  it 'keeps every failing case, its message and its file:line' do
    result = compress(failures)

    expect(result).to include('not ok 3 - falha na comparação', 'not ok 4 - lança')
    expect(result).to include("expected: 'other@y.com'", "actual: 'x@y.com'", "error: 'boom'")
    expect(result).to include('t.test.js:5:1', 't.test.js:6:1')
  end

  # The message of an assertion lives on the lines *after* `error: |-`, so a
  # line-by-line filter kept the `|-` and dropped the sentence — the one thing
  # a failure is read for.
  it 'keeps the body of a multi-line error block' do
    expect(compress(failures)).to include('Expected values to be strictly equal')
  end

  it 'drops the runner internals and keeps the frame in the user code' do
    result = compress(failures)

    expect(result).not_to include('node:internal/test_runner')
    expect(result).to include('t.test.js:5:44')
  end

  # The counts are the verdict and come from the runner's own tail. Recounting
  # them here would be a second implementation that can disagree with the tool.
  it 'keeps the plan and the counts whole' do
    result = compress(failures)

    expect(result).to include('1..4', '# tests 4', '# pass 2', '# fail 2')
  end

  it 'reduces a passing run to its verdict' do
    result = compress(passing)

    expect(result.bytesize).to be < passing.bytesize / 4
    expect(result).to include('# pass 8', '# fail 0')
    expect(result).not_to include('duration_ms: 0.69814')
  end

  describe 'what it refuses' do
    it 'stands aside without a command naming node' do
      expect(described_class.applicable?('bundle exec rspec', failures)).to be(false)
    end

    # Other runners emit TAP. Claiming their output would be rewriting text
    # this compressor has never seen the shape of.
    it 'stands aside for TAP that carries none of this runner’s markers' do
      tap = "TAP version 13\nok 1 - something else\n1..1\n"

      expect(described_class.output_match?(tap)).to be(false)
    end

    it 'leaves what another command on the same line printed' do
      chained = "#{failures}\nline 40 of the file\n"

      expect(compress(chained, command: 'node --test && cat notes.txt'))
        .to include('line 40 of the file')
    end
  end
end
