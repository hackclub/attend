require "rails_helper"

RSpec.describe Guardian do
  before do
    ActiveRecord::Encryption.config.primary_key = "a" * 32
    ActiveRecord::Encryption.config.deterministic_key = "b" * 32
    ActiveRecord::Encryption.config.key_derivation_salt = "c" * 32
  end

  it "stores encrypted contact details while preserving model accessors" do
    guardian = create(
      :guardian,
      phone: "+12025559876",
      address_line_1: "123 Main St",
      city: "San Francisco"
    )

    raw = described_class.connection.select_one(
      described_class.sanitize_sql_array([
        "SELECT phone, address_line_1, city FROM guardians WHERE id = ?",
        guardian.id
      ])
    )

    expect(raw["phone"]).not_to eq("+12025559876")
    expect(raw["address_line_1"]).not_to eq("123 Main St")
    expect(raw["city"]).not_to eq("San Francisco")

    expect(guardian.reload.phone).to eq("+12025559876")
    expect(guardian.address_line_1).to eq("123 Main St")
    expect(guardian.city).to eq("San Francisco")
  end

  describe "email vs the participant's email" do
    it "rejects an email change onto a linked participant's address" do
      gpe = create(:guardian_participant_event)
      participant = gpe.participant_event.participant

      gpe.guardian.email = participant.email.upcase

      expect(gpe.guardian).not_to be_valid
      expect(gpe.guardian.errors[:email])
        .to include("cannot be the same as the participant's email address")
    end

    it "allows unrelated edits on a guardian whose email already collides" do
      gpe = create(:guardian_participant_event)
      participant = gpe.participant_event.participant
      guardian = gpe.guardian
      guardian.update_column(:email, participant.email)

      expect(guardian.reload.update(legal_first_name: "Robin")).to be(true)
    end

    it "leaves guardians of other participants alone" do
      guardian = create(:guardian)
      create(:participant, email: "someone-else@example.com")

      expect(guardian.update(email: "someone-else@example.com")).to be(true)
    end
  end
end
