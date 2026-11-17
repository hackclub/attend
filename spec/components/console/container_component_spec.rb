require "rails_helper"

RSpec.describe Console::ContainerComponent, type: :component do
  it "renders a titled box with a padded body" do
    render_inline(described_class.new("Ban details")) { "Body" }

    expect(rendered_content).to eq(
      '<section class="cs-container"><div class="cs-container-header"><h2 class="cs-h2">Ban details</h2></div>' \
      '<div class="cs-container-body">Body</div></section>'
    )
  end

  it "stacks a description under the title, beside the actions" do
    render_inline(described_class.new("API access", description: "Programmatic access to add and list participants")) do |box|
      box.with_actions { '<a class="cs-btn cs-btn-link" href="/docs">API docs</a>'.html_safe }
      "Body"
    end

    expect(rendered_content).to eq(
      '<section class="cs-container"><div class="cs-container-header">' \
      '<div><h2 class="cs-h2">API access</h2><p class="cs-container-description">Programmatic access to add and list participants</p></div>' \
      '<div class="cs-actions"><a class="cs-btn cs-btn-link" href="/docs">API docs</a></div></div>' \
      '<div class="cs-container-body">Body</div></section>'
    )
  end

  it "renders the counter as muted text after the title, never a badge" do
    render_inline(described_class.new("Current events", counter: 0, divided: true, flush: true)) { "<table></table>".html_safe }

    expect(rendered_content).to eq(
      '<section class="cs-container"><div class="cs-container-header cs-container-header-divided">' \
      '<h2 class="cs-h2">Current events <span class="cs-counter">(0)</span></h2></div><table></table></section>'
    )
  end

  it "renders a footer, body classes, and no header without a title" do
    render_inline(described_class.new(body_class: "cs-stack", footer_class: "flex justify-end", tag: :div, id: "box")) do |box|
      box.with_footer { "Save" }
      "Body"
    end

    expect(rendered_content).to eq(
      '<div class="cs-container" id="box"><div class="cs-container-body cs-stack">Body</div>' \
      '<div class="cs-container-footer flex justify-end">Save</div></div>'
    )
  end

  it "matches the hand-written kit container" do
    handwritten = <<~HTML
      <section class="cs-container"><div class="cs-container-header cs-container-header-divided"><div><h2 class="cs-h2">Existing event enrollments <span class="cs-counter">(2)</span></h2><p class="cs-container-description">This ban does not remove anyone already added.</p></div></div><div class="cs-container-body">Rows</div></section>
    HTML
    rendered = kit.cs_container("Existing event enrollments", counter: 2, divided: true,
      description: "This ban does not remove anyone already added.") { "Rows" }

    expect(dom(rendered)).to eq(dom(handwritten.strip))
  end
end
