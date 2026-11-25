require "rails_helper"

RSpec.describe Console::BadgeComponent, type: :component do
  it "renders a grey chip by default and a coloured one when asked" do
    render_inline(described_class.new("Draft"))
    expect(rendered_content).to eq('<span class="cs-badge">Draft</span>')

    render_inline(described_class.new("Has staff", "yellow"))
    expect(rendered_content).to eq('<span class="cs-badge cs-badge-yellow">Has staff</span>')
  end

  it "renders a severity badge, humanizing the severity and falling back to neutral" do
    render_inline(described_class.severity("critical"))
    expect(rendered_content).to eq('<span class="cs-badge cs-badge-severity-critical">Critical</span>')

    render_inline(described_class.severity("unheard_of", "S9"))
    expect(rendered_content).to eq('<span class="cs-badge cs-badge-severity-neutral">S9</span>')
  end

  it "matches what cs_badge and cs_severity_badge emitted before the component layer" do
    [ [ "Draft" ], [ "A & B", "green" ], [ "Staff", :yellow ], [ nil, "red" ] ].each do |args|
      expect(kit.cs_badge(*args)).to eq(kit.legacy_cs_badge(*args))
    end
    [ [ "critical" ], [ :high ], [ "medium", "S2" ], [ "low" ], [ "neutral" ], [ "unheard_of" ], [ nil ] ].each do |args|
      expect(kit.cs_severity_badge(*args)).to eq(kit.legacy_cs_severity_badge(*args))
    end
  end
end
