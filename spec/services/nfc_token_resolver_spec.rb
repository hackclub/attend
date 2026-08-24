require "rails_helper"

RSpec.describe NfcTokenResolver do
  let(:event) { create(:event) }

  it "resolves an assigned event badge only at its event" do
    participation = create(:participant_event, event: event)
    participation.assign_nfc_badge!(user: create(:user))
    other_event = create(:event)

    expect(described_class.call(event: event, token: participation.nfc_badge_token)).to eq(participation)
    expect(described_class.call(event: other_event, token: participation.nfc_badge_token)).to be_nil
  end

  it "does not resolve an event badge before assignment" do
    participation = create(:participant_event, event: event)

    expect(described_class.call(event: event, token: participation.nfc_badge_token)).to be_nil
  end

  it "resolves an active passport to its owner's participation at every event" do
    owner = create(:user)
    participant = create(:participant, user: owner)
    first_participation = create(:participant_event, event: event, participant: participant)
    second_participation = create(:participant_event, event: create(:event), participant: participant)
    passport = create(:passport, :active, user: owner)

    expect(described_class.call(event: event, token: passport.token)).to eq(first_participation)
    expect(described_class.call(event: second_participation.event, token: passport.token)).to eq(second_participation)
  end

  it "does not resolve pending or revoked passports" do
    owner = create(:user)
    participant = create(:participant, user: owner)
    create(:participant_event, event: event, participant: participant)
    pending = create(:passport, user: owner)
    revoked = create(:passport, :revoked, user: owner)

    expect(described_class.call(event: event, token: pending.token)).to be_nil
    expect(described_class.call(event: event, token: revoked.token)).to be_nil
  end

  it "does not resolve a passport without an owner participation at the selected event" do
    owner = create(:user)
    participant = create(:participant, user: owner)
    create(:participant_event, participant: participant)
    passport = create(:passport, :active, user: owner)

    expect(described_class.call(event: event, token: passport.token)).to be_nil
  end

  it "does not resolve a passport for a user without a participant" do
    passport = create(:passport, :active)

    expect(described_class.call(event: event, token: passport.token)).to be_nil
  end

  it "returns nil for blank, malformed, and unknown tokens" do
    expect(described_class.call(event: event, token: nil)).to be_nil
    expect(described_class.call(event: event, token: "not-a-uuid")).to be_nil
    expect(described_class.call(event: event, token: SecureRandom.uuid)).to be_nil
  end

  it "gives an assigned current-event badge precedence over a passport" do
    owner = create(:user)
    participant = create(:participant, user: owner)
    passport_participation = create(:participant_event, event: event, participant: participant)
    passport = create(:passport, :active, user: owner)
    badge_participation = create(:participant_event, event: event)
    badge_participation.update_columns(
      nfc_badge_token: passport.token,
      nfc_badge_assigned_at: Time.current,
      nfc_badge_assigned_by_id: create(:user).id
    )

    expect(described_class.call(event: event, token: passport.token)).to eq(badge_participation)
    expect(described_class.call(event: event, token: passport.token)).not_to eq(passport_participation)
  end
end
