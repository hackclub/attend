require "rails_helper"

RSpec.describe Portal::FieldComponent, type: :component do
  it "renders the label and the control in a wrapper" do
    render_inline(described_class.new("Email", for: "contact_email").with_content('<input id="contact_email" class="portal-input">'.html_safe))

    expect(rendered_content).to eq(
      '<div><label class="portal-label" for="contact_email">Email</label><input id="contact_email" class="portal-input"></div>'
    )
  end

  it "marks a required field with the same asterisk label_text appends" do
    render_inline(described_class.new("Full Name", for: "name", required: true).with_content("CONTROL"))

    expect(rendered_content).to eq(
      '<div><label class="portal-label" for="name">Full Name<span class="text-red-500 ml-0.5">*</span></label>CONTROL</div>'
    )
    expect(rendered_content).to include(kit.label_text("Full Name", required: true))
  end

  it "puts the hint between the label and the control" do
    render_inline(described_class.new("Email address or phone number", for: "contact", hint: "Use whichever one is on file.").with_content("CONTROL"))

    expect(rendered_content).to eq(
      '<div><label class="portal-label" for="contact">Email address or phone number</label>' \
      '<p class="portal-hint text-sm mb-3">Use whichever one is on file.</p>CONTROL</div>'
    )
  end

  it "drops the wrapper for a field that sits directly in its form" do
    render_inline(described_class.new("Verification code", for: "code", wrapper: false).with_content("CONTROL"))

    expect(rendered_content).to eq('<label class="portal-label" for="code">Verification code</label>CONTROL')
  end

  it "takes wrapper classes and attributes" do
    render_inline(described_class.new("Email", for: "email", class: "sm:col-span-2", data: { testid: "f" }).with_content("CONTROL"))

    expect(rendered_content).to eq('<div class="sm:col-span-2" data-testid="f"><label class="portal-label" for="email">Email</label>CONTROL</div>')
  end

  it "matches the builder labels it replaced" do
    form = ActionView::Helpers::FormBuilder.new(:emergency_contact, EmergencyContact.new, kit, {})

    required = kit.portal_field("Full Name", for: form.field_id(:name), required: true) { form.text_field(:name, class: "portal-input", required: true) }
    handwritten = kit.content_tag(:div, form.label(:name, kit.label_text("Full Name", required: true), class: "portal-label") +
      form.text_field(:name, class: "portal-input", required: true))
    expect(required).to eq(handwritten)

    bare = kit.portal_field("Verification code", for: "code", wrapper: false) { kit.text_field_tag(:code, nil, class: "portal-input") }
    expect(dom(bare)).to eq(dom(kit.label_tag(:code, "Verification code", class: "portal-label") + kit.text_field_tag(:code, nil, class: "portal-input")))
  end
end
