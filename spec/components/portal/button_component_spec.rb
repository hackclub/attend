require "rails_helper"

RSpec.describe Portal::ButtonComponent, type: :component do
  it "renders a submit button in each variant" do
    render_inline(described_class.new("Verify", variant: :primary, class: "w-full sm:w-auto mt-4"))
    expect(rendered_content).to eq('<button type="submit" class="portal-btn portal-btn-primary w-full sm:w-auto mt-4">Verify</button>')

    render_inline(described_class.new("Send a new code", variant: :quiet))
    expect(rendered_content).to eq('<button type="submit" class="portal-btn portal-btn-quiet">Send a new code</button>')

    render_inline(described_class.new("Back", variant: :secondary, type: "button"))
    expect(rendered_content).to eq('<button type="button" class="portal-btn portal-btn-secondary">Back</button>')

    render_inline(described_class.new("Email me a code", class: "w-full sm:w-auto mt-4"))
    expect(rendered_content).to eq('<button type="submit" class="portal-btn w-full sm:w-auto mt-4">Email me a code</button>')
  end

  it "renders a link that looks like a button when given an href" do
    render_inline(described_class.new("Find my portals", variant: :primary, href: "/guardian/portals", class: "w-full sm:w-auto"))

    expect(rendered_content).to eq('<a class="portal-btn portal-btn-primary w-full sm:w-auto" href="/guardian/portals">Find my portals</a>')
  end

  it "takes block content" do
    render_inline(described_class.new(variant: :primary)) { "<span>Go</span>".html_safe }

    expect(rendered_content).to eq('<button type="submit" class="portal-btn portal-btn-primary"><span>Go</span></button>')
  end

  it "rejects a variant the kit doesn't have" do
    expect { described_class.new("Go", variant: :danger) }.to raise_error(ArgumentError, /unknown portal-btn variant/)
  end

  it "hands builders the same class string" do
    expect(kit.portal_button_classes).to eq("portal-btn")
    expect(kit.portal_button_classes(:secondary, "w-full sm:w-auto")).to eq("portal-btn portal-btn-secondary w-full sm:w-auto")
  end

  it "matches the hand-written portal buttons it replaced" do
    expect(dom(kit.portal_button("Verify", variant: :primary, class: "w-full sm:w-auto mt-4")))
      .to eq(dom('<button type="submit" class="portal-btn portal-btn-primary w-full sm:w-auto mt-4">Verify</button>'))
    expect(kit.portal_button("Find my portals", variant: :primary, href: "/guardian/portals", class: "w-full sm:w-auto"))
      .to eq(kit.link_to("Find my portals", "/guardian/portals", class: "portal-btn portal-btn-primary w-full sm:w-auto"))
  end
end
