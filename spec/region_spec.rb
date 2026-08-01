# frozen_string_literal: true

RSpec.describe LeanOutput::Region do
  def span(text, **opts) = described_class.span(text, **opts)

  let(:core) { /^MARK/ }

  it 'reaches from the first recognised line to the end of the last' do
    text = "other\nMARK one\nfiller\nMARK two\nother\n"
    expect(text[span(text, core: core)]).to eq("MARK one\nfiller\nMARK two\n")
  end

  it 'is nil when nothing is recognised' do
    expect(span("nothing here\n", core: core)).to be_nil
  end

  it 'keeps unmarked lines that sit between two marked ones' do
    text = "MARK\n\n\nMARK\n"
    expect(text[span(text, core: core)]).to eq(text)
  end

  it 'grows backwards over lines that carry no marker of their own' do
    text = "foreign\n...\nMARK\n"
    expect(text[span(text, core: core, back: /^\.+$/)]).to eq("...\nMARK\n")
  end

  it 'grows forwards over lines that carry no marker of their own' do
    text = "MARK\n+added\nforeign\n"
    expect(text[span(text, core: core, forward: /^\+/)]).to eq("MARK\n+added\n")
  end

  it 'crosses a blank line to reach a claimable one' do
    text = "foreign\n...\n\nMARK\n"
    expect(text[span(text, core: core, back: /^(\.+|\s*)$/)]).to eq("...\n\nMARK\n")
  end

  it 'gives back a blank line it would otherwise end on' do
    # The blank separating us from whatever ran before belongs to neither side,
    # and claiming it would delete the previous command's last newline.
    text = "foreign\n\nMARK\n"
    expect(text[span(text, core: core, back: /^\s*$/)]).to eq("MARK\n")
  end

  it 'keeps a blank line that opens the buffer, since nothing is behind it' do
    text = "\nMARK\n"
    expect(text[span(text, core: core, back: /^\s*$/)]).to eq(text)
  end
end
