require "rails_helper"

RSpec.describe Portal::CardComponent, type: :component do
  it "renders a card with the caller's spacing" do
    render_inline(described_class.new(class: "p-5 sm:p-6 mb-6")) { "Body" }

    expect(rendered_content).to eq('<div class="portal-card p-5 sm:p-6 mb-6">Body</div>')
  end

  it "renders a bare card, another element, and passes attributes through" do
    render_inline(described_class.new) { "Body" }
    expect(rendered_content).to eq('<div class="portal-card">Body</div>')

    render_inline(described_class.new(tag: :section, class: "p-5 sm:p-6", id: "contact", data: { testid: "card" })) { "Body" }
    expect(rendered_content).to eq('<section class="portal-card p-5 sm:p-6" id="contact" data-testid="card">Body</section>')
  end

  it "renders the sunken panel" do
    render_inline(described_class.new(panel: true, class: "p-5")) { "Body" }

    expect(rendered_content).to eq('<div class="portal-panel p-5">Body</div>')
  end

  it "matches the hand-written portal surfaces through the helpers" do
    expect(kit.portal_card(class: "p-5 sm:p-6 mb-6") { "Body" }).to eq('<div class="portal-card p-5 sm:p-6 mb-6">Body</div>')
    expect(kit.portal_card(tag: :section, class: "p-5 sm:p-6") { "Body" }).to eq('<section class="portal-card p-5 sm:p-6">Body</section>')
    expect(kit.portal_panel(class: "p-5") { "Body" }).to eq('<div class="portal-panel p-5">Body</div>')
  end
end
