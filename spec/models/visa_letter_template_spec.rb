require "rails_helper"

RSpec.describe VisaLetterTemplate do
  let(:event) { create(:event, name: "Fictional Hackathon", location_city: "Boston", location_country: "United States") }
  let(:application) do
    build(:visa_letter_application, event: event, full_name: "Ada <b>Example</b> & Co", reference_number: "HC-TEST1234",
      letter_event_name: "Fictional Hackathon", letter_city: "Boston", letter_country: "United States",
      letter_starts_on: Date.new(2027, 3, 5), letter_ends_on: Date.new(2027, 3, 7), letter_issued_on: Date.new(2026, 10, 28))
  end

  it "fills in placeholders from the application's frozen details, escaping what the applicant typed" do
    template = build(:visa_letter_template, body: "Dear officer, {{participant_full_name}} attends {{ event_name }} " \
      "({{event_date_range}}), reference {{reference_number}}, issued {{current_date}}. Signed {{signatory_name}}. {{not_a_placeholder}}" + ("." * 60))

    rendered = template.render(application)

    expect(rendered).to include("Ada &lt;b&gt;Example&lt;/b&gt; &amp; Co attends Fictional Hackathon (March 5–7, 2027)")
    expect(rendered).to include("reference HC-TEST1234, issued October 28, 2026. Signed Fictional Signatory.")
    expect(rendered).to include("{{not_a_placeholder}}")
  end

  it "allows only one global default" do
    create(:visa_letter_template, :default)

    expect(build(:visa_letter_template, :default)).not_to be_valid
    expect(build(:visa_letter_template, is_default: true, event: event)).to be_valid
  end

  it "falls back to the global default when the event has no active template of its own" do
    default = create(:visa_letter_template, :default)
    create(:visa_letter_template, event: event, active: false)

    expect(described_class.for_event(event)).to eq(default)
    expect(described_class.for_event(create(:event))).to eq(default)
  end

  it "only takes a PNG or JPEG signature" do
    template = build(:visa_letter_template)
    template.signature_image.attach(io: StringIO.new("not an image"), filename: "signature.txt", content_type: "text/plain")

    expect(template).not_to be_valid
    expect(template.errors[:signature_image]).to include("must be a PNG or JPEG")
  end
end
