require "rails_helper"

RSpec.describe NfcTokenResolver do
  let(:event) { create(:event, nfc_badges_enabled: false) }
  let(:owner) { create(:user) }
  let(:participant) { create(:participant, user: owner) }
  let!(:participation) { create(:participant_event, event: event, participant: participant) }

  it "resolves an active personal token in the selected event" do
    token = create(:nfc_token, :active, user: owner)

    expect(described_class.call(event: event, token: token.token)).to eq(participation)
  end

  it "returns nil when the owner is not participating in the selected event" do
    token = create(:nfc_token, :active)

    expect(described_class.call(event: event, token: token.token)).to be_nil
  end

  it "rejects pending and unknown tokens" do
    pending = create(:nfc_token, user: owner)

    expect(described_class.call(event: event, token: pending.token)).to be_nil
    expect(described_class.call(event: event, token: SecureRandom.uuid)).to be_nil
    expect(described_class.call(event: event, token: "not-a-uuid")).to be_nil
  end

  it "does not let a revoked personal token fall through to a matching legacy badge" do
    token = create(:nfc_token, :revoked, user: owner)
    participation.update_columns(
      nfc_badge_token: token.token,
      nfc_badge_assigned_at: 1.day.ago
    )

    expect(described_class.call(event: event, token: token.token)).to be_nil
  end

  it "resolves an assigned linked legacy badge across events" do
    legacy_event = create(:event)
    legacy = create(:participant_event, event: legacy_event, participant: participant)
    legacy.update_columns(nfc_badge_assigned_at: 1.day.ago)

    expect(described_class.call(event: event, token: legacy.nfc_badge_token)).to eq(participation)
  end

  it "limits an assigned unlinked legacy badge to its original event" do
    unlinked = create(:participant_event)
    unlinked.update_columns(nfc_badge_assigned_at: 1.day.ago)

    expect(described_class.call(event: unlinked.event, token: unlinked.nfc_badge_token)).to eq(unlinked)
    expect(described_class.call(event: event, token: unlinked.nfc_badge_token)).to be_nil
  end

  it "rejects an unassigned legacy token" do
    legacy = create(:participant_event, event: event)

    expect(described_class.call(event: event, token: legacy.nfc_badge_token)).to be_nil
  end
end
