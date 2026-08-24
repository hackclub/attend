require "rails_helper"
require Rails.root.join("db/migrate/20260824130003_backfill_user_owned_nfc_tokens")

RSpec.describe BackfillUserOwnedNfcTokens do
  it "copies assigned linked tokens without changing legacy rows" do
    owner = create(:user)
    staff = create(:user)
    linked = create(:participant, user: owner)
    linked_participation = create(:participant_event, participant: linked)
    assigned_at = 2.days.ago.change(usec: 0)
    linked_token = SecureRandom.uuid
    linked_participation.update_columns(
      nfc_badge_token: linked_token,
      nfc_badge_assigned_at: assigned_at,
      nfc_badge_assigned_by_id: staff.id
    )

    unlinked_participation = create(:participant_event)
    unlinked_token = SecureRandom.uuid
    unlinked_participation.update_columns(
      nfc_badge_token: unlinked_token,
      nfc_badge_assigned_at: assigned_at,
      nfc_badge_assigned_by_id: staff.id
    )

    expect { described_class.new.up }.to change(NfcToken, :count).by(1)

    migrated = NfcToken.find_by!(token: linked_token)
    expect(migrated.user).to eq(owner)
    expect(migrated.paired_at).to be_within(1.second).of(assigned_at)
    expect(migrated.paired_by).to eq(staff)
    expect(NfcToken.find_by(token: unlinked_token)).to be_nil
    expect(linked_participation.reload.nfc_badge_token).to eq(linked_token)

    expect { described_class.new.up }.not_to change(NfcToken, :count)
  end
end
