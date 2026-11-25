require "rails_helper"

RSpec.describe Console::FieldComponent, type: :component do
  let(:error_icon) { vc_test_controller.view_context.cs_status_icon(:error) }

  it "renders the label, the control and the validation hooks" do
    render_inline(described_class.new(id: "add-room-name", label: "Room name or number").with_content('<input id="add-room-name">'.html_safe))

    expect(rendered_content).to eq(
      '<div class="cs-field" data-cs-field="true" data-cs-label="Room name or number" data-cs-error-id="add-room-name-error">' \
      '<label for="add-room-name" class="cs-field-label">Room name or number</label><input id="add-room-name"></div>'
    )
  end

  it "renders optional, description, error and constraint in Cloudscape's order" do
    component = described_class.new(id: "slug", label: "Slug", optional: true, description: "Used in links.",
      constraint: "Lowercase letters only.", errors: [ "", "Slug is required.", "Second" ], warning: "Hidden by the error")
    render_inline(component.with_content("CONTROL"))

    expect(rendered_content).to eq(
      '<div class="cs-field" data-cs-field="true" data-cs-label="Slug" data-cs-error-id="slug-error">' \
      '<label for="slug" class="cs-field-label">Slug<span class="cs-field-optional"> - optional</span></label>' \
      '<p class="cs-field-description" id="slug-description">Used in links.</p>CONTROL' \
      "<p class=\"cs-field-error\" id=\"slug-error\" data-cs-server-error=\"true\">#{error_icon}<span>Slug is required.</span></p>" \
      '<p class="cs-field-hint" id="slug-constraint">Lowercase letters only.</p></div>'
    )
  end

  it "works out the control's aria attributes before rendering" do
    plain = described_class.new(id: "name", label: "Name")
    expect(plain.control_attributes).to eq(aria: {})

    invalid = described_class.new(id: "name", label: "Name", errors: [ "Name is required." ], description: "d", constraint: "c", warning: "w")
    expect(invalid.control_attributes).to eq(aria: { invalid: true, describedby: "name-error name-description name-constraint" })

    warned = described_class.new(id: "name", label: "Name", warning: "Careful")
    expect(warned.control_attributes).to eq(aria: { describedby: "name-warning" })
  end

  it "matches what cs_field emitted before the component layer" do
    cases = [
      { id: "a", label: "Plain" },
      { id: "b", label: "Optional & described", optional: true, description: "Why", constraint: "How" },
      { id: "c", label: "Invalid", errors: [ "Is <bad>.", "Second" ], constraint: "How" },
      { id: "d", label: "Warned", warning: "Careful", description: "Why" },
      { id: "e", label: "Error beats warning", errors: "One", warning: "Careful" },
      { id: "f", label: "Group", group: true, description: "Pick some", data: { controller: "nested-form" } },
      { id: "g", label: "Hidden label", hide_label: true, label_class: "cs-small" },
      { id: "h", label: "Bare", bare: true, class: "mt-4", hidden: true },
      { id: "i", label: "Extras", class: "sm:col-span-2", data: { cs_label: "Overridden", testid: "x" } }
    ]

    cases.each do |options|
      current = kit.cs_field(**options.deep_dup) { |aria| kit.text_field_tag(options[:id], "v", class: "cs-input", **aria) }
      legacy = kit.legacy_cs_field(**options.deep_dup) { |aria| kit.text_field_tag(options[:id], "v", class: "cs-input", **aria) }

      expect(current).to eq(legacy), "cs_field(#{options.inspect}) drifted"
    end
  end

  it "matches what cs_field_message emitted before the component layer" do
    %i[error warning].each do |type|
      expect(kit.cs_field_message(type, "A <b> & c", id: "x-#{type}", data: { cs_server_error: true }))
        .to eq(kit.legacy_cs_field_message(type, "A <b> & c", id: "x-#{type}", data: { cs_server_error: true }))
    end
  end

  it "keeps cs_form_field rendering through it" do
    event = Event.new
    event.errors.add(:name, :blank)
    form = ActionView::Helpers::FormBuilder.new(:event, event, kit, {})

    html = Nokogiri::HTML5.fragment(kit.cs_form_field(form, :name, constraint: "Shown to participants."))

    expect(html.at_css(".cs-field > label.cs-field-label[for='event_name']").text).to eq("Name")
    expect(html.at_css("input.cs-input#event_name")["aria-describedby"]).to eq("event_name-error event_name-constraint")
    expect(html.at_css("#event_name-error").text).to eq("Name is required.")
  end
end
