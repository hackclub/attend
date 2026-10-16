require "rails_helper"

RSpec.describe ConnectedAccount do
  let(:participant) { create(:participant) }

  def build_account(**attrs)
    participant.connected_accounts.build({
      provider: "github", uid: "1", username: "octocat", access_token: "gho_secret", connected_at: Time.current
    }.merge(attrs))
  end

  it "encrypts the access token" do
    account = build_account
    account.save!

    raw = ConnectedAccount.connection.select_value("SELECT access_token FROM connected_accounts WHERE id = #{ConnectedAccount.connection.quote(account.id)}")
    expect(raw).not_to include("gho_secret")
    expect(account.reload.access_token).to eq("gho_secret")
  end

  it "allows one account per provider per participant" do
    build_account.save!

    expect(build_account(uid: "2", username: "other")).not_to be_valid
    expect(build_account(provider: "itch")).to be_valid
  end

  it "links to the profile" do
    expect(build_account.profile_url).to eq("https://github.com/octocat")
    expect(build_account(provider: "itch", username: "maker").profile_url).to eq("https://maker.itch.io")
    expect(build_account(profile: { "url" => "https://example.itch.io" }).profile_url).to eq("https://example.itch.io")
  end
end
