# frozen_string_literal: true

RSpec.describe LeanOutput::Compressors::GitDiff do
  describe 'a commit mixing hand-written and vendored files' do
    let(:original) { fixture('git_show_vendored.txt') }
    subject(:compressed) { described_class.compress(original) }

    it 'keeps every hand-written hunk byte for byte' do
      %w[
        app/javascript/controllers/editor_controller.js
        app/views/file_browser/_viewer.html.erb
        config/importmap.rb
        CLAUDE.md
      ].each do |path|
        block = original[%r{^diff --git a/#{Regexp.escape(path)} .*?(?=^diff --git |\z)}m]
        expect(compressed).to include(block)
      end
    end

    it 'keeps the commit message preamble' do
      expect(compressed).to include('F6: CodeMirror 6 editor')
    end

    it 'still names every vendored file that changed' do
      %w[crelt.js style-mod.js @codemirror--state.js].each do |file|
        expect(compressed).to include("diff --git a/vendor/javascript/#{file}")
      end
    end

    it 'replaces the vendored bodies with a line count' do
      expect(compressed).to match(%r{^\[lean-output\] generated file — \+\d+/-\d+ lines, body collapsed$})
      expect(compressed).not_to include('class RangeSet')
    end

    it 'reduces size by at least 75% on this fixture' do
      expect(compressed.bytesize).to be < original.bytesize * 0.25
    end
  end

  describe 'a diff with nothing generated in it' do
    it 'returns nil rather than rewriting a diff it cannot shrink' do
      expect(described_class.compress(fixture('git_show_plain.txt'))).to be_nil
    end
  end

  describe 'applicability' do
    let(:diff) { fixture('git_show_vendored.txt') }

    it 'recognizes diff and show, with or without -C' do
      ['git diff', 'git diff HEAD -- app/', 'git -C /tmp/repo show 87209f8', 'git show'].each do |command|
        expect(described_class).to be_applicable(command, diff)
      end
    end

    it 'ignores git commands that are not diffs' do
      expect(described_class).not_to be_applicable('git log --stat', diff)
      expect(described_class).not_to be_applicable('git status', diff)
    end

    it 'ignores diff-shaped commands with no diff in the output' do
      expect(described_class).not_to be_applicable('git diff --stat', " 3 files changed\n")
    end
  end

  describe 'unrecognizable output' do
    it 'returns nil' do
      expect(described_class.compress('some random output')).to be_nil
    end
  end
end
