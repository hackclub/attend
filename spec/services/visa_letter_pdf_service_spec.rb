require "rails_helper"

RSpec.describe VisaLetterPdfService do
  let(:event) do
    create(:event, name: "Fictional Hackathon", location_city: "Boston", location_country: "United States",
      timezone: "Eastern Time (US & Canada)", starts_at: Time.utc(2027, 3, 5, 15), ends_at: Time.utc(2027, 3, 7, 22))
  end
  let(:template) { create(:visa_letter_template, :default) }
  let(:application) do
    create(:visa_letter_application, event: event, full_name: "Ada Example", date_of_birth: Date.new(2008, 4, 1)).tap do |application|
      application.send(:snapshot_letter_details, Date.new(2026, 10, 28))
    end
  end

  # Squished, since the reader breaks wrapped lines wherever the layout did.
  def text_of(pdf)
    PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n").squish
  end

  it "prints the letter, the signatory and the footer embassies check" do
    text = text_of(described_class.new(application, template: template).generate)

    expect(text).to include("October 28, 2026")
    expect(text).to include("Ada Example has been invited to attend Fictional Hackathon from March 5–7, 2027 in Boston, United States.")
    expect(text).to include("Reference Number: #{application.reference_number}")
    expect(text).to include("Fictional Signatory")
    expect(text).to include("ADA EXAMPLE • DOB: 2008-04-01")
    expect(text).to include("Verify this letter at hack.club/visa-verify")
    expect(text).to include(application.verification_code)
  end

  it "locks the PDF against editing but lets it be printed" do
    pdf = described_class.new(application, template: template).generate

    expect(pdf).to include("/Encrypt")
    expect(PDF::Reader.new(StringIO.new(pdf)).page_count).to be >= 1
  end

  it "embeds the template's signature image" do
    template.signature_image.attach(io: file_fixture("headshot.png").open, filename: "signature.png", content_type: "image/png")

    pdf = described_class.new(application, template: template).generate

    expect(PDF::Reader.new(StringIO.new(pdf)).pages.first.xobjects).not_to be_empty
  end
end
