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

  it "emails the participant with the staff follow-up and request link" do
    event = create(:event, name: "Test Summit", support_email: "events@hackclub.com")
    participant = create(:participant, email: "participant@example.com", preferred_name: "Pat")
    participant_event = create(:participant_event, event: event, participant: participant)
    requester = create(:user, email: participant.email)
    change_request = RegistrationChangeRequest.create!(
      participant_event: participant_event,
      requested_by: requester,
      kind: :support,
      staff_audience: :event_admin,
      requester_note: "Please help",
      status: :follow_up_needed,
      staff_response: "Please add the time you can be reached.")

    mail = described_class.participant_follow_up(change_request: change_request)
    content = [ mail.subject, mail.text_part.body.decoded, mail.html_part.body.decoded ].join(" ")

    expect(mail.to).to eq([ "participant@example.com" ])
    expect(mail.from).to include("events@hackclub.com")
    expect(content).to include("Please add the time you can be reached.")
    expect(content).to include("/dashboard/events/#{participant_event.id}/change_requests/#{change_request.id}")
  end

  describe "#participant_approved" do
    let(:event) { create(:event, name: "Test Summit", support_email: "events@hackclub.com") }
    let(:participant) { create(:participant, email: "participant@example.com", preferred_name: "Pat") }

    def approved_request(status:, **attributes)
      participant_event = create(:participant_event, event: event, participant: participant, status: status, **attributes)
      RegistrationChangeRequest.create!(
        participant_event: participant_event,
        requested_by: create(:user, email: participant.email),
        kind: :signed_identity,
        staff_audience: :event_admin,
        requested_changes: { "date_of_birth" => "2010-05-05" },
        status: :approved)
    end

    it "sends someone still registering back into onboarding" do
      change_request = approved_request(status: :in_progress)

      mail = described_class.participant_approved(change_request: change_request)
      content = [ mail.subject, mail.text_part.body.decoded, mail.html_part.body.decoded ].join(" ")

      expect(mail.to).to eq([ "participant@example.com" ])
      expect(mail.from).to include("events@hackclub.com")
      expect(mail.subject).to eq("Your Test Summit signed identity request was approved")
      expect(content).to include("Continue registering")
      expect(content).to include("/onboarding?event_id=#{event.id}")
      expect(content).not_to include("2010-05-05")
    end

    it "sends someone who has submitted to their registration" do
      change_request = approved_request(status: :complete, onboarding_completed_at: Time.current)

      mail = described_class.participant_approved(change_request: change_request)
      content = [ mail.text_part.body.decoded, mail.html_part.body.decoded ].join(" ")

      expect(content).to include("View your registration")
      expect(content).to include("/dashboard/events/#{change_request.participant_event.id}")
      expect(content).not_to include("/onboarding")
    end
  end
end
