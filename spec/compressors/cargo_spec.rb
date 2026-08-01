# frozen_string_literal: true

RSpec.describe LeanOutput::Compressors::Cargo do
  describe '#applicable?' do
    let(:errors_output) { fixture('cargo_errors.txt') }
    let(:warnings_output) { fixture('cargo_warnings.txt') }

    it 'matches cargo build with error output' do
      expect(described_class.applicable?('cargo build', errors_output)).to be true
    end

    it 'matches cargo check' do
      expect(described_class.applicable?('cargo check', errors_output)).to be true
    end

    it 'matches cargo clippy' do
      expect(described_class.applicable?('cargo clippy', warnings_output)).to be true
    end

    it 'matches cargo test when compilation failed before any test ran' do
      expect(described_class.applicable?('cargo test', errors_output)).to be true
    end

    it 'matches cargo build inside a longer command' do
      expect(described_class.applicable?('cd myproject && cargo build', errors_output)).to be true
    end

    it 'returns false for --message-format=json' do
      expect(described_class.applicable?('cargo build --message-format=json', errors_output)).to be false
    end

    it 'returns false for --message-format json' do
      expect(described_class.applicable?('cargo build --message-format json', errors_output)).to be false
    end

    it 'returns false when command does not include cargo' do
      expect(described_class.applicable?('bundle exec rspec', errors_output)).to be false
    end

    it 'returns false when output has no cargo diagnostics' do
      expect(described_class.applicable?('cargo build', 'some random output')).to be false
    end

    context 'output this compressor cannot rebuild' do
      it 'refuses libtest output, whose panic sites are not rustc art' do
        harness = fixture('cargo_test_harness.txt')
        expect(described_class.applicable?('cargo test', harness)).to be false
      end

      it 'refuses a cargo run that compiled, since program stdout follows' do
        expect(described_class.applicable?('cargo run', warnings_output)).to be false
      end

      it 'still handles a cargo run that failed to compile' do
        expect(described_class.applicable?('cargo run', errors_output)).to be true
      end

      it 'refuses a diagnostic with no location line' do
        expect(described_class.applicable?('cargo build', "error: linking with `cc` failed\n")).to be false
      end
    end
  end

  describe 'errors fixture' do
    let(:original) { fixture('cargo_errors.txt') }
    subject(:compressed) { compress_with(described_class, original) }

    it 'starts with a summary line listing error count and failure reason' do
      expect(compressed.lines.first).to match(/Cargo: 4 errors/)
      expect(compressed.lines.first).to include('could not compile')
    end

    it 'keeps file:line:col for every error' do
      expect(compressed).to include('src/main.rs:8:27')
      expect(compressed).to include('src/main.rs:9:24')
      expect(compressed).to include('src/main.rs:11:16')
      expect(compressed).to include('src/main.rs:12:5')
    end

    it 'keeps the error code for every diagnostic' do
      expect(compressed).to include('E0308')
      expect(compressed).to include('E0600')
      expect(compressed).to include('E0425')
    end

    it 'keeps the diagnostic message text' do
      expect(compressed).to include('mismatched types')
      expect(compressed).to include('cannot apply unary operator `-` to type `u32`')
      expect(compressed).to include('cannot find function `undefined_function` in this scope')
    end

    it 'keeps note: and help: text' do
      expect(compressed).to include('unsigned values cannot be negated')
      expect(compressed).to include('you may have meant the maximum value of `u32`')
      expect(compressed).to include('try using a conversion method')
    end

    it 'keeps caret labels (the informative text after ^^^ or ---)' do
      expect(compressed).to include('expected `i32`, found `&str`')
      expect(compressed).to include('cannot apply unary operator `-`')
      expect(compressed).to include('expected `String`, found `&str`')
      expect(compressed).to include('arguments to this method are incorrect')
      expect(compressed).to include('not found in this scope')
    end

    it 'keeps note: with external location (method defined here)' do
      expect(compressed).to include('method defined here')
    end

    it 'drops source echo lines (pure code lines inside the art block)' do
      expect(compressed).not_to include('let wrong_type: i32 = "not an integer"')
      expect(compressed).not_to include('let missing: u32 = -1')
    end

    it 'drops pure-caret lines (no label text)' do
      # a line that is only pipes and carets/dashes and whitespace with no label
      expect(compressed).not_to match(/^\s+\|\s*[-^~]+\s*$/)
    end

    it 'drops Compiling progress lines' do
      expect(compressed).not_to include('Compiling leanfx')
    end

    it 'drops the rustc --explain footer' do
      expect(compressed).not_to include('For more information about an error')
      expect(compressed).not_to include('rustc --explain')
    end

    it 'drops the Some errors have detailed explanations footer' do
      expect(compressed).not_to include('Some errors have detailed explanations')
    end

    it 'reduces size on the errors fixture' do
      expect(compressed.bytesize).to be < original.bytesize * 0.70
    end
  end

  describe 'warnings fixture' do
    let(:original) { fixture('cargo_warnings.txt') }
    subject(:compressed) { compress_with(described_class, original) }

    it 'starts with a summary line listing warning count' do
      expect(compressed.lines.first).to match(/Cargo: 7 warnings/)
    end

    it 'keeps file:line:col for every warning' do
      expect(compressed).to include('src/main.rs:10:9')
      expect(compressed).to include('src/main.rs:9:9')
      expect(compressed).to include('src/main.rs:11:9')
      expect(compressed).to include('src/main.rs:14:9')
      expect(compressed).to include('src/main.rs:3:4')
      expect(compressed).to include('src/main.rs:4:4')
      expect(compressed).to include('src/main.rs:6:8')
    end

    it 'keeps warning message text' do
      expect(compressed).to include('variable does not need to be mutable')
      expect(compressed).to include('unused variable: `unused_var`')
      expect(compressed).to include('function `unused_helper` is never used')
      expect(compressed).to include('struct `UnusedStruct` is never constructed')
    end

    it 'keeps note: text' do
      expect(compressed).to include('#[warn(unused_mut)]')
      expect(compressed).to include('#[warn(dead_code)]')
    end

    it 'keeps inline help labels from caret lines' do
      expect(compressed).to include('if this is intentional, prefix it with an underscore: `_unused_var`')
    end

    it 'drops Compiling progress lines' do
      expect(compressed).not_to include('Compiling leanfx')
    end

    it 'drops Finished lines' do
      expect(compressed).not_to include('Finished')
    end

    it 'drops the cargo fix suggestion footer' do
      expect(compressed).not_to include('run `cargo fix')
    end

    it 'reduces size on the warnings fixture' do
      expect(compressed.bytesize).to be < original.bytesize * 0.70
    end
  end

  describe 'ANSI-colored errors output' do
    let(:original) { fixture('cargo_errors_ansi.txt') }
    subject(:compressed) { compress_with(described_class, original) }

    it 'produces plain text without ANSI escapes' do
      expect(compressed).not_to include("\e[")
    end

    it 'keeps the error count summary' do
      expect(compressed.lines.first).to match(/Cargo: 4 errors/)
    end

    it 'keeps file:line:col locations' do
      expect(compressed).to include('src/main.rs:8:27')
      expect(compressed).to include('src/main.rs:12:5')
    end

    it 'keeps error codes' do
      expect(compressed).to include('E0308')
      expect(compressed).to include('E0425')
    end

    it 'keeps caret labels' do
      expect(compressed).to include('expected `i32`, found `&str`')
      expect(compressed).to include('not found in this scope')
    end

    it 'keeps note: and help: text' do
      expect(compressed).to include('unsigned values cannot be negated')
      expect(compressed).to include('try using a conversion method')
    end
  end

  describe 'ANSI-colored warnings output' do
    let(:original) { fixture('cargo_warnings_ansi.txt') }
    subject(:compressed) { compress_with(described_class, original) }

    it 'produces plain text without ANSI escapes' do
      expect(compressed).not_to include("\e[")
    end

    it 'keeps the warning count summary' do
      expect(compressed.lines.first).to match(/Cargo: 7 warnings/)
    end

    it 'keeps inline help labels' do
      expect(compressed).to include('if this is intentional, prefix it with an underscore: `_unused_var`')
    end
  end

  describe '--message-format=json (not applicable)' do
    let(:original) { fixture('cargo_errors.txt') }

    it 'is not applicable when --message-format=json is present' do
      expect(described_class.applicable?('cargo build --message-format=json', original)).to be false
    end

    it 'is not applicable when --message-format json (space) is present' do
      expect(described_class.applicable?('cargo build --message-format json', original)).to be false
    end
  end

  describe 'clean / short output' do
    let(:original) { fixture('cargo_clean.txt') }

    it 'returns nil (no diagnostic lines means no gain)' do
      expect(compress_with(described_class, original)).to be_nil
    end

    it 'is not applicable (no diagnostics in output)' do
      expect(described_class.applicable?('cargo build', original)).to be false
    end
  end

  describe 'unrecognizable output' do
    it 'returns nil for output with no cargo diagnostics' do
      expect(compress_with(described_class, 'some random output without cargo diagnostics')).to be_nil
    end
  end
end
