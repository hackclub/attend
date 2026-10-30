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

  # Line by line in the order they're drawn, squished: the watermark and
  # footer overlap the body, which scrambles the reader's page layout.
  def text_of(pdf)
    PDF::Reader.new(StringIO.new(pdf)).pages.flat_map { |page| page.runs(merge: true).map(&:text) }.join(" ").squish
  end

  it "prints the letter, the signatory and the footer embassies check" do
    text = text_of(described_class.new(application, template: template).generate)

    expect(text).to include("October 28, 2026")
    expect(text).to include("Ada Example has been invited to attend Fictional Hackathon from March 5–7, 2027 in Boston, United States.")
    expect(text).to include("Reference Number: #{application.reference_number}")
    expect(text).to include("Fictional Signatory")
    # Letter-spaced microtext, which the reader spaces out.
    expect(text.delete(" ")).to include("ADAEXAMPLE•DOB:2008-04-01")
    expect(text).to include("Verify this letter at hack.club/visa-verify")
    expect(text).to include(application.verification_code)
  end

  it "locks the PDF against editing but lets it be printed" do
    pdf = described_class.new(application, template: template).generate

    expect(pdf).to include("/Encrypt")
    expect(PDF::Reader.new(StringIO.new(pdf)).page_count).to be >= 1
  end

  it "fits on one page, signed with Envoy's signature unless the template has its own" do
    images = ->(pdf) { PDF::Reader.new(StringIO.new(pdf)).pages.first.xobjects.values.map { |image| image.hash[:Height] } }

    pdf = described_class.new(application, template: template).generate
    expect(PDF::Reader.new(StringIO.new(pdf)).page_count).to eq(1)
    default_signed = images.(pdf)
    expect(default_signed.size).to eq(2) # the wordmark and the signature

    template.signature_image.attach(io: file_fixture("headshot.png").open, filename: "signature.png", content_type: "image/png")
    expect(images.(described_class.new(application, template: template).generate)).not_to eq(default_signed)
  end

  it "prints a multi-line address on one line, as Envoy's letters did" do
    template.body = "Address: {{participant_address}}"
    application.address = "2 Sample Road\nExample City, EX1 2AB\nUnited Kingdom"

    expect(template.render(application)).to eq("Address: 2 Sample Road, Example City, EX1 2AB, United Kingdom")
  end
end
