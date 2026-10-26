require "rails_helper"

RSpec.describe BackfillVerifiedSlackIdsJob, type: :job do
  def stale_user(slack_id)
    user = create(:user, oidc_claims: { "slack_id" => slack_id })
    user.update_column(:verified_slack_id, nil)
    user
  end

  it "fills the column from the claims for rows that are missing or wrong" do
    missing = stale_user("U0FAKE111")
    wrong = create(:user, oidc_claims: { "slack_id" => "U0FAKE222" })
    wrong.update_column(:verified_slack_id, "U0WRONG99")
    no_claims = create(:user, oidc_claims: nil)

    result = described_class.perform_now

    expect(missing.reload.verified_slack_id).to eq("U0FAKE111")
    expect(wrong.reload.verified_slack_id).to eq("U0FAKE222")
    expect(no_claims.reload.verified_slack_id).to be_nil
    expect(result).to include(repaired: 2, failed: 0)
  end

  it "is idempotent: a second run writes nothing" do
    stale_user("U0FAKE111")
    described_class.perform_now

    expect(described_class.perform_now).to include(repaired: 0, failed: 0)
  end

  it "keeps going when one row raises" do
    bad = stale_user("U0FAKE111")
    good = stale_user("U0FAKE222")

    allow(User).to receive(:verified_slack_id_from).and_call_original
    allow(User).to receive(:verified_slack_id_from)
      .with(hash_including("slack_id" => "U0FAKE111"))
      .and_raise(ActiveRecord::Encryption::Errors::Decryption)

    result = described_class.perform_now

    expect(bad.reload.verified_slack_id).to be_nil
    expect(good.reload.verified_slack_id).to eq("U0FAKE222")
    expect(result).to include(failed: 1)
  end
end
