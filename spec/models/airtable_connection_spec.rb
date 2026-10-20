require "rails_helper"

RSpec.describe AirtableConnection do
  let(:event) { create(:event) }
  let(:token_url) { "https://airtable.com/oauth2/v1/token" }

  def connection(**attrs)
    described_class.create!({
      event: event,
      access_token: "fictional-old-access",
      refresh_token: "fictional-old-refresh",
      access_token_expires_at: 1.hour.from_now,
      refresh_token_expires_at: 60.days.from_now
    }.merge(attrs))
  end

  def stub_refresh
    stub_request(:post, token_url).with(body: hash_including(grant_type: "refresh_token", refresh_token: "fictional-old-refresh"))
      .to_return(status: 200, body: {
        access_token: "fictional-new-access", refresh_token: "fictional-new-refresh",
        scope: "data.records:write", expires_in: 3600, refresh_expires_in: 5_184_000
      }.to_json)
  end

  describe "#fresh_access_token!" do
    it "uses the current token while it has time left" do
      expect(connection.fresh_access_token!).to eq("fictional-old-access")
      expect(WebMock).not_to have_requested(:post, token_url)
    end

    it "refreshes a token about to expire and keeps the rotated refresh token" do
      stub_refresh
      record = connection(access_token_expires_at: 1.minute.from_now)

      expect(record.fresh_access_token!).to eq("fictional-new-access")
      expect(record.reload.refresh_token).to eq("fictional-new-refresh")
      expect(record.access_token_expires_at).to be > 50.minutes.from_now
    end

    # Each refresh token works once, so a job that waited on the lock must
    # use the token the other job just got rather than spend the old one.
    it "doesn't refresh again when another process already has" do
      stale = connection(access_token_expires_at: 1.minute.from_now)
      described_class.find(stale.id).update!(
        access_token: "fictional-other-access",
        refresh_token: "fictional-other-refresh",
        access_token_expires_at: 1.hour.from_now
      )

      expect(stale.fresh_access_token!).to eq("fictional-other-access")
      expect(WebMock).not_to have_requested(:post, token_url)
    end

    it "asks for a reconnect once the refresh token has lapsed" do
      record = connection(access_token_expires_at: 1.day.ago, refresh_token_expires_at: 1.minute.ago)

      expect { record.fresh_access_token! }.to raise_error(Airtable::AuthenticationError, /Reconnect Airtable/)
    end
  end

  it "keeps tokens encrypted at rest" do
    record = connection
    raw = described_class.connection.select_value("SELECT access_token FROM airtable_connections WHERE id = #{described_class.connection.quote(record.id)}")

    expect(raw).not_to include("fictional-old-access")
  end
end
