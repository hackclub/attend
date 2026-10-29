require "rails_helper"

RSpec.describe ParticipantRegistration do
  let(:event) { create(:event) }

  describe ".register_invitee!" do
    it "registers someone new as invited, with placeholders for a name it wasn't given" do
      registration = described_class.register_invitee!(event: event, email: "new.person@example.com", first_name: nil, last_name: nil,
        details: { date_of_birth: Date.new(2009, 5, 1) })

      expect(registration).to have_attributes(event: event, status: "invited")
      expect(registration.participant).to have_attributes(email: "new.person@example.com", legal_first_name: "Unknown",
        legal_last_name: "Unknown", date_of_birth: Date.new(2009, 5, 1))
    end

    it "finds an existing person by email in any case, fills only what's missing, and yields them" do
      existing = create(:participant, email: "Known.Person@example.com", legal_first_name: "Unknown", legal_last_name: "Unknown", phone: nil)

      yielded = nil
      registration = described_class.register_invitee!(event: event, email: "known.person@example.com", first_name: "Kim",
        last_name: "Sample", details: { phone: "+12025550188", date_of_birth: Date.new(2000, 1, 1) }) { |participant| yielded = participant }

      expect(registration.participant).to eq(existing)
      expect(existing.reload).to have_attributes(legal_first_name: "Kim", legal_last_name: "Sample", phone: "+12025550188")
      expect(existing.date_of_birth).not_to eq(Date.new(2000, 1, 1))
      expect(yielded).to eq(existing)
    end

    it "doesn't save or yield when there's nothing to fill in" do
      existing = create(:participant, email: "complete@example.com")

      expect { |block|
        described_class.register_invitee!(event: event, email: "complete@example.com", first_name: "Other", last_name: "Name", &block)
      }.not_to yield_control
      expect(existing.reload.legal_first_name).to eq("John")
    end

    it "uses the participant it's given over an email match, and keeps a registration they already have" do
      known = create(:participant, email: "someone.else@example.com")
      create(:participant, email: "shared@example.com")
      registration = create(:participant_event, participant: known, event: event, status: :complete)

      expect(described_class.register_invitee!(event: event, email: "shared@example.com", first_name: nil, last_name: nil, participant: known))
        .to eq(registration)
      expect(registration.reload).to be_complete
    end
  end
end
