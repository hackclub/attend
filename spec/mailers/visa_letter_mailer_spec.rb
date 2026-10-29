require "rails_helper"

RSpec.describe VisaLetterMailer do
  let(:event) { create(:event, name: "Fictional Hackathon", support_email: "fictional@hackclub.com") }
  let(:application) { create(:visa_letter_application, event: event, full_name: "Ada Example", email: "ada@example.com") }

  before { create(:visa_letter_template, :default) }

  it "sends the letter itself, from the event's support address" do
    application.approve!(by: create(:user))
    application.issue_letter!

    mail = described_class.letter_ready(application: application)

    expect(mail.to).to eq([ "ada@example.com" ])
    expect(mail.from).to eq([ "fictional@hackclub.com" ])
    expect(mail.subject).to eq("Your visa invitation letter for Fictional Hackathon")
    expect(mail.attachments.map(&:filename)).to eq([ "visa-letter-#{application.reference_number}.pdf" ])
    [ mail.html_part, mail.text_part ].each do |part|
      expect(part.body.to_s).to include("Hi Ada", application.reference_number, "hack.club/visa-verify")
    end
  end

  it "tells a soft-rejected applicant why, and that they can apply again" do
    application.reject!(by: create(:user), reason: "The name doesn't match your passport.")

    mail = described_class.rejected(application: application)

    [ mail.html_part, mail.text_part ].each do |part|
      body = CGI.unescapeHTML(part.body.to_s)
      expect(body).to include("The name doesn't match your passport.")
      expect(body).to include("apply again")
    end
  end

  it "doesn't offer a hard-rejected applicant another go" do
    application.reject!(by: create(:user), reason: "Not eligible.", type: :hard)

    expect(described_class.rejected(application: application).text_part.body.to_s).not_to include("apply again")
  end
end
