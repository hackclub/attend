require "rails_helper"

RSpec.describe Console::ButtonComponent, type: :component do
  it "renders a normal button that doesn't submit unless told to" do
    render_inline(described_class.new("Cancel"))

    expect(rendered_content).to eq('<button type="button" class="cs-btn">Cancel</button>')
  end

  it "renders the primary, link and icon variants" do
    render_inline(described_class.new("Create room", variant: :primary, type: "submit"))
    expect(rendered_content).to eq('<button type="submit" class="cs-btn cs-btn-primary">Create room</button>')

    render_inline(described_class.new("Cancel", variant: :link, data: { hide: "add-room-modal" }))
    expect(rendered_content).to eq('<button type="button" class="cs-btn cs-btn-link" data-hide="add-room-modal">Cancel</button>')

    render_inline(described_class.new(variant: :icon, "aria-label": "Close").with_content("x"))
    expect(rendered_content).to eq('<button type="button" class="cs-btn cs-btn-icon" aria-label="Close">x</button>')
  end

  it "renders a link that looks like a button when given an href" do
    render_inline(described_class.new("New context", href: "/admin/contexts/new"))

    expect(rendered_content).to eq('<a class="cs-btn" href="/admin/contexts/new">New context</a>')
  end

  it "appends the full-width modifier and the caller's classes after the kit's" do
    render_inline(described_class.new("Save", variant: :primary, full: true, class: "mt-4"))

    expect(rendered_content).to eq('<button type="button" class="cs-btn cs-btn-primary cs-btn-full mt-4">Save</button>')
  end

  it "rejects a variant the kit doesn't have" do
    expect { described_class.new("Save", variant: :danger) }.to raise_error(ArgumentError, /unknown cs-btn variant/)
  end

  it "hands builders the same class string" do
    expect(described_class.classes).to eq("cs-btn")
    expect(described_class.classes(variant: :primary)).to eq("cs-btn cs-btn-primary")
    expect(kit.cs_button_classes(:link, "cs-filter-clear")).to eq("cs-btn cs-btn-link cs-filter-clear")
  end

  it "matches the hand-written kit buttons" do
    expect(dom(kit.cs_button("Create room", variant: :primary, type: "submit")))
      .to eq(dom('<button type="submit" class="cs-btn cs-btn-primary">Create room</button>'))
    expect(dom(kit.cs_button("Cancel", variant: :link, data: { hide: "add-room-modal" })))
      .to eq(dom('<button type="button" data-hide="add-room-modal" class="cs-btn cs-btn-link">Cancel</button>'))
    expect(kit.cs_button("Clear", href: "/admin/bans")).to eq(kit.link_to("Clear", "/admin/bans", class: "cs-btn"))
  end

  it "keeps the buttons other helpers emit unchanged" do
    tokens = [ { label: "Status", operator: "=", value: "Active", remove_href: "/x" } ]
    expect(kit.cs_filter_tokens(tokens, clear_href: "/all"))
      .to end_with('<a class="cs-btn cs-btn-link cs-filter-clear" href="/all">Clear filters</a></div>')

    form = ActionView::Helpers::FormBuilder.new(:event, nil, kit, {})
    expect(kit.cs_settings_save(form))
      .to eq('<div class="cs-container-footer flex justify-end"><button name="button" type="submit" class="cs-btn cs-btn-primary">Save</button></div>')
  end
end
