require "rails_helper"

RSpec.describe Console::AlertComponent, type: :component do
  let(:warning_icon) { vc_test_controller.view_context.cs_status_icon(:warning) }
  let(:info_icon) { vc_test_controller.view_context.cs_status_icon(:info) }

  it "renders the status icon and the body" do
    render_inline(described_class.new(:warning)) { "<p>No recipients match.</p>".html_safe }

    expect(rendered_content).to eq(%(<div class="cs-alert cs-alert-warning">#{warning_icon}<div><p>No recipients match.</p></div></div>))
  end

  it "renders info as the bare cs-alert, which is how the kit spells it" do
    render_inline(described_class.new) { "Visa letters are off." }

    expect(rendered_content).to eq(%(<div class="cs-alert">#{info_icon}<div>Visa letters are off.</div></div>))
  end

  it "puts a bold title above the body and passes attributes through" do
    render_inline(described_class.new(:warning, title: "Invitations are held", tag: :section, class: "mb-5", data: { testid: "held" })) { "<p>Body</p>".html_safe }

    expect(rendered_content).to eq(
      %(<section class="cs-alert cs-alert-warning mb-5" data-testid="held">#{warning_icon}) +
      '<div><p class="cs-alert-title">Invitations are held</p><p>Body</p></div></section>'
    )
  end

  it "rejects a type the kit doesn't have" do
    expect { described_class.new(:danger) }.to raise_error(ArgumentError, /unknown cs-alert type/)
  end

  it "matches the hand-written kit alert" do
    handwritten = <<~HTML
      <div class="cs-alert cs-alert-warning">#{warning_icon}<div><p class="cs-alert-title">Onboarding invitations are held for this event.</p><p>Their invitation goes out later.</p></div></div>
    HTML
    rendered = kit.cs_alert(:warning, title: "Onboarding invitations are held for this event.") { kit.tag.p("Their invitation goes out later.") }

    expect(dom(rendered)).to eq(dom(handwritten.strip))
  end

  it "matches what cs_form_alert emitted before the component layer" do
    [
      [ [ "Name is required." ], {} ],
      [ [ "Name is required." ], { title: "Fix this" } ],
      [ [ "Name is required.", "Enter a valid <email>." ], {} ],
      [ [ "One", "Two", "", nil ], { title: "Two problems" } ],
      [ [], {} ],
      [ nil, { title: "Nothing" } ]
    ].each do |messages, options|
      expect(kit.cs_form_alert(messages, **options)).to eq(kit.legacy_cs_form_alert(messages, **options))
    end
  end
end
