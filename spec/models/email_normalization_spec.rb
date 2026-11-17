require "rails_helper"

RSpec.describe "Email normalisation on write" do
  it "strips and downcases a participant's email" do
    participant = create(:participant, email: "  Robin.Vale@Example.COM ")

    expect(participant.reload.email).to eq("robin.vale@example.com")
  end

  it "strips and downcases a guardian's email" do
    guardian = create(:guardian, email: " Morgan.Vale@Example.com")

    expect(guardian.reload.email).to eq("morgan.vale@example.com")
  end

  it "strips and downcases an emergency contact's email, leaving a missing one alone" do
    registration = create(:participant_event)
    contact = EmergencyContact.create!(participant_event: registration, name: "Sam Vale", phone: "+12025550143", email: "Sam.Vale@Example.com ")
    without = EmergencyContact.create!(participant_event: registration, name: "Jo Vale", phone: "+12025550144")

    expect(contact.reload.email).to eq("sam.vale@example.com")
    expect(without.reload.email).to be_nil
  end

  it "normalises on paths that skip validation" do
    participant = create(:participant)
    participant.email = "Robin.Vale@Example.com"
    participant.save!(validate: false)

    expect(participant.reload.email).to eq("robin.vale@example.com")
  end

  it "leaves blank-email queries meaning what they did before" do
    present = create(:participant)
    blank = store_legacy_email(create(:participant), "")

    expect(Participant.where.not(email: [ nil, "" ])).to contain_exactly(present)
    expect(Participant.where(email: [ nil, "" ])).to contain_exactly(blank)
  end

  it "does not rewrite a legacy mixed-case row that is saved for something else" do
    participant = store_legacy_email(create(:participant), "Legacy.Row@example.com")

    participant.update!(preferred_name: "Robin")

    expect(participant.reload.email).to eq("Legacy.Row@example.com")
  end

  describe "the guardian / participant collision checks" do
    let(:participant) { create(:participant, email: "robin.vale@example.com") }
    let(:registration) { create(:participant_event, participant:) }
    let(:guardian) { create(:guardian, email: "morgan.vale@example.com") }

    before { create(:guardian_participant_event, guardian:, participant_event: registration) }

    it "still stops a guardian taking their participant's address in another case" do
      expect(guardian.update(email: "Robin.Vale@EXAMPLE.com")).to be(false)
      expect(guardian.errors[:email]).to be_present
    end

    it "still stops a participant taking their guardian's address in another case" do
      expect(participant.update(email: " Morgan.Vale@example.com")).to be(false)
      expect(participant.errors[:email]).to be_present
    end

    it "still sees a legacy mixed-case row on the other side" do
      store_legacy_email(participant, "Robin.Vale@Example.com")

      expect(guardian.update(email: "robin.vale@example.com")).to be(false)
    end

    it "lets a legacy colliding guardian be edited without touching the email" do
      store_legacy_email(guardian, "Robin.Vale@example.com")

      expect(guardian.update(legal_first_name: "Morgana")).to be(true)
    end
  end
end
