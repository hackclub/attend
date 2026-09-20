require "rails_helper"

RSpec.describe RegistrationCorrectionMailer, type: :mailer do
  it "notifies staff without including submitted or stored participant values" do
    event = create(:event, name: "Test Summit")
    participant = create(:participant,
      legal_first_name: "SensitiveLegalName",
      email: "sensitive-participant@example.com",
      phone: "+12025550191")
    participant_event = create(:participant_event, event: event, participant: participant)
    recipient = create(:user, email: "staff@example.com")

    mail = described_class.staff_notification(
      recipient: recipient,
      participant_event: participant_event,
      section: "health"
    )
    content = [ mail.subject, mail.text_part.body.decoded, mail.html_part.body.decoded ].join(" ")

    expect(mail.to).to eq([ "staff@example.com" ])
    expect(content).to include("health and accessibility information")
    expect(content).to include("/admin/events/#{event.slug}/participants/#{participant_event.id}")
    expect(content).not_to include("SensitiveLegalName")
    expect(content).not_to include("sensitive-participant@example.com")
    expect(content).not_to include("+12025550191")
  end
end
