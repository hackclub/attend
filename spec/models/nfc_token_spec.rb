require "rails_helper"

RSpec.describe NfcToken, type: :model do
  let(:owner) { create(:user) }
  let(:staff) { create(:user) }

  it "starts pending and confirms only with its token" do
    nfc_token = described_class.create!(user: owner)

    expect(nfc_token).to be_pending
    expect {
      nfc_token.confirm!(presented_token: nfc_token.token, actor: staff)
    }.to change(nfc_token, :active?).from(false).to(true)

    expect(nfc_token.paired_by).to eq(staff)
    expect(nfc_token.paired_at).to be_present
  end

  it "rejects a mismatched token without confirming" do
    nfc_token = described_class.create!(user: owner)

    expect {
      nfc_token.confirm!(presented_token: SecureRandom.uuid, actor: staff)
    }.to raise_error(NfcToken::TokenMismatch)

    expect(nfc_token.reload).to be_pending
  end

  it "does not confirm a revoked token" do
    nfc_token = create(:nfc_token, :revoked, user: owner)

    expect {
      nfc_token.confirm!(presented_token: nfc_token.token, actor: staff)
    }.to raise_error(NfcToken::InvalidState)
  end

  it "reuses a pending token for a user" do
    pending = described_class.ensure_pending_for!(owner)

    expect(described_class.ensure_pending_for!(owner)).to eq(pending)
  end

  it "allows multiple active tokens for one user and revokes only one" do
    first = create(:nfc_token, :active, user: owner)
    second = create(:nfc_token, :active, user: owner)

    first.revoke!(actor: staff)

    expect(first.reload).not_to be_active
    expect(first.revoked_by).to eq(staff)
    expect(second.reload).to be_active
  end

  it "enforces globally unique token values" do
    existing = create(:nfc_token, user: owner)

    duplicate = build(:nfc_token, token: existing.token)
    expect(duplicate).not_to be_valid
  end
end
