require "rails_helper"

RSpec.describe ParticipantMailer, type: :mailer do
  describe "#waiver_ready" do
    it "does not describe the waiver as completing an adult registration while another document remains" do
      event = create(:event, name: "Trailblazer")
      participant = create(:participant, date_of_birth: 18.years.ago)
      participant_event = create(:participant_event, event: event, participant: participant,
        code_of_conduct_accepted_at: Time.current)
      create(:consent, participant_event: participant_event, status: :sent,
        docuseal_participant_slug: "participant")
      document = create(:custom_document, event: event, name: "Hotel waiver")
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: document, docuseal_participant_slug: "hotel")

      mail = described_class.waiver_ready(participant_event: participant_event)

      [ mail.html_part.body.decoded, mail.text_part.body.decoded ].each do |body|
        expect(body).to include("remaining steps")
        expect(body).not_to include("to complete your registration")
      end
    end
  end

  describe "#registration_confirmed" do
    it "tells the attendee that the entry ticket is ready" do
      event = create(:event, name: "Trailblazer")
      participant = create(:participant, email: "attendee@example.com")
      participant_event = create(:participant_event, event: event, participant: participant, status: :complete)

      mail = described_class.registration_confirmed(participant_event: participant_event)
      body = [ mail.html_part.body.decoded, mail.text_part.body.decoded ].join("\n")

      expect(mail.subject).to eq("Your entry ticket is ready for Trailblazer")
      expect(body).to include("registration for")
      expect(body).to include("entry ticket is ready")
      expect(body).to include("dashboard")
    end
  end

  describe "#invitation" do
    def decoded_parts(mail)
      [ mail.html_part.body.decoded, mail.text_part.body.decoded ]
    end

    it "replies to the event's configured support email" do
      event = create(:event, support_email: "organizers@hackclub.com")

      mail = described_class.invitation(
        email: "participant@example.com",
        event: event
      )

      expect(mail.reply_to).to eq([ "organizers@hackclub.com" ])
    end

    # Resending is the same call twice: the admin's Resend Invitation action
    # relies on the second send reusing the pending invite, so the link the
    # participant already has keeps working.
    it "reuses the pending invitation instead of issuing a new token" do
      event = create(:event)
      participant = create(:participant, email: "resend@example.com")

      first = described_class.invitation(email: participant.email, event: event, participant: participant)
      first.deliver_now
      invitation = event.invitations.pending.sole

      second = described_class.invitation(email: participant.email, event: event, participant: participant)
      second.deliver_now

      expect(event.invitations.pending.pluck(:id)).to eq([ invitation.id ])
      expect(second.body.encoded).to include(invitation.token)
    end

    it "issues a fresh invitation once the old one has expired" do
      event = create(:event)
      participant = create(:participant, email: "expired@example.com")
      stale = Invitation.create!(event: event, email: participant.email)
      # Only a sent invitation can expire: the link's window runs from the send.
      stale.update_columns(sent_at: 31.days.ago, expires_at: 1.day.ago)

      described_class.invitation(email: participant.email, event: event, participant: participant).deliver_now

      expect(event.invitations.pending.count).to eq(1)
      expect(event.invitations.pending.first.id).not_to eq(stale.id)
    end

    it "briefs the attendee with the configured event details and materials" do
      event = create(:event,
        name: "Trailblazer",
        timezone: "Pacific Time (US & Canada)",
        starts_at: "2026-10-02T09:00",
        ends_at: "2026-10-04T17:00",
        registration_close_at: "2026-09-20T17:00",
        venue_name: "Summit Hall",
        location_address: "123 Pine Street",
        location_city: "Oakland",
        location_country: "USA")

      mail = described_class.invitation(email: "participant@example.com", event: event)

      expect(mail.subject).to eq("Complete your registration for Trailblazer")

      decoded_parts(mail).each do |body|
        expect(body).to include("October 2 - 4, 2026")
        expect(body).to include("Summit Hall")
        expect(body).to include("123 Pine Street")
        expect(body).to include("September 20, 2026 at 5:00 PM PDT")
        expect(body).to include("clear photo of your face")
        expect(body).to include("travel details")
        expect(body).to include("accommodation")
        expect(body).to include("save your progress")
        expect(body).to include("resume")
      end
    end

    it "explains the guardian handoff to a known minor" do
      event = create(:event, starts_at: Time.zone.local(2026, 10, 2))
      participant = create(:participant, date_of_birth: Date.new(2010, 1, 1))

      mail = described_class.invitation(
        email: participant.email,
        event: event,
        participant: participant
      )

      decoded_parts(mail).each do |body|
        expect(body).to include("guardian contact details")
        expect(body).to include("separate invitation")
        expect(body).to include("required signatures")
      end
    end

    it "does not tell a known adult that guardian details are required" do
      event = create(:event, starts_at: Time.zone.local(2026, 10, 2))
      participant = create(:participant, date_of_birth: Date.new(2000, 1, 1))

      mail = described_class.invitation(
        email: participant.email,
        event: event,
        participant: participant
      )

      decoded_parts(mail).each do |body|
        expect(body).not_to include("guardian contact details")
        expect(body).not_to include("separate invitation")
        expect(body).not_to include("parent/guardian")
      end
    end

    it "uses conditional guardian language when age is not known" do
      event = create(:event, starts_at: Time.zone.local(2026, 10, 2))

      mail = described_class.invitation(email: "participant@example.com", event: event)

      decoded_parts(mail).each do |body|
        expect(body).to include("If you'll be under 18")
        expect(body).to include("guardian contact details")
      end
    end

    it "does not invent a deadline or disabled event sections" do
      event = create(:event,
        registration_close_at: nil,
        travel_enabled: false,
        accommodation_enabled: false)

      mail = described_class.invitation(email: "participant@example.com", event: event)

      decoded_parts(mail).each do |body|
        expect(body).to include("clear photo of your face")
        expect(body).not_to include("Complete your registration by")
        expect(body).not_to include("travel details")
        expect(body).not_to include("accommodation")
      end
    end
  end
end
