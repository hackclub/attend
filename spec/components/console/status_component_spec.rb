require "rails_helper"

RSpec.describe Console::StatusComponent, type: :component do
  it "renders the icon and the word in the status colour" do
    render_inline(described_class.new(:success, "Checked in"))

    expect(rendered_content).to eq(
      '<span class="cs-status cs-status-success">' \
      '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' \
      '<circle cx="8" cy="8" r="7"/><path d="M4.5 8.2l2.3 2.3 4.7-4.9"/></svg>' \
      "<span>Checked in</span></span>"
    )
  end

  it "dasherizes the type in the class and falls back to info for an unknown one" do
    expect(render_inline(described_class.new("in_progress", "Syncing")).at_css("span")["class"]).to eq("cs-status cs-status-in-progress")
    expect(render_inline(described_class.new(:mystery, "?")).at_css("span")["class"]).to eq("cs-status cs-status-info")
  end

  it "escapes the label" do
    render_inline(described_class.new(:info, "<b>x</b>"))

    expect(rendered_content).to include("<span>&lt;b&gt;x&lt;/b&gt;</span>")
  end

  it "matches what cs_status and cs_status_icon emitted before the component layer" do
    [ :success, :error, :warning, :info, :pending, :in_progress, :stopped, "in_progress", :mystery, nil ].each do |type|
      expect(kit.cs_status(type, "A & B")).to eq(kit.legacy_cs_status(type, "A & B"))
    end
    LegacyKitMarkup::STATUS_ICONS.each_key do |type|
      expect(kit.cs_status_icon(type)).to eq(kit.legacy_cs_status_icon(type))
      render_inline(Console::StatusIconComponent.new(type))
      expect(rendered_content).to eq(kit.legacy_cs_status_icon(type))
    end
  end

  it "keeps raising for an unknown bare icon, as cs_status_icon always has" do
    expect { kit.cs_status_icon(:mystery) }.to raise_error(KeyError)
  end
end
