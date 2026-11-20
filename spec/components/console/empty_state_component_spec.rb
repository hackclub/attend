require "rails_helper"

RSpec.describe Console::EmptyStateComponent, type: :component do
  it "renders a bold title on its own" do
    render_inline(described_class.new("No applications here"))

    expect(rendered_content).to eq('<div class="cs-empty"><p class="cs-empty-title">No applications here</p></div>')
  end

  it "renders the description and centred actions" do
    render_inline(described_class.new("No scan contexts", "No scan contexts configured for this event.")) do |empty|
      empty.with_actions { '<a class="cs-btn" href="/new">New context</a>'.html_safe }
    end

    expect(rendered_content).to eq(
      '<div class="cs-empty"><p class="cs-empty-title">No scan contexts</p>' \
      "<p>No scan contexts configured for this event.</p>" \
      '<div class="cs-actions"><a class="cs-btn" href="/new">New context</a></div></div>'
    )
  end

  it "appends the caller's classes and passes attributes through" do
    render_inline(described_class.new("Nothing", class: "flex-1", hidden: true))

    expect(rendered_content).to eq('<div class="cs-empty flex-1" hidden="hidden"><p class="cs-empty-title">Nothing</p></div>')
  end

  it "matches what cs_no_match emitted before the component layer" do
    [ {}, { clear_href: "/admin/bans" }, { clear_href: "/admin/bans?a=1&b=2", id: "no-match", hidden: true, data: { cs_table_target: "empty" } } ].each do |options|
      expect(kit.cs_no_match(**options)).to eq(kit.legacy_cs_no_match(**options))
    end
  end

  it "matches the hand-written kit empty state" do
    handwritten = <<~HTML
      <div class="cs-empty"><p class="cs-empty-title">No series yet</p><p>A series groups related events.</p><div class="cs-actions"><a class="cs-btn" href="/admin/series/new">Create series</a></div></div>
    HTML
    rendered = kit.cs_empty("No series yet", "A series groups related events.") do |empty|
      empty.with_actions { kit.cs_button("Create series", href: "/admin/series/new") }
    end

    expect(dom(rendered)).to eq(dom(handwritten.strip))
  end
end
