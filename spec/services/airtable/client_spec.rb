require "rails_helper"

RSpec.describe Airtable::Client do
  subject(:client) { described_class.new(api_key: "key-test", base_id: "appTest") }

  let(:sync_url) { "https://api.airtable.com/v0/appTest/tblTest/sync/sncTest" }
  let(:records_url) { "https://api.airtable.com/v0/appTest/Participants" }

  before do
    # Skip the retry middleware's real backoff sleeps.
    allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep)
  end

  describe "#post_sync_csv" do
    it "retries a gateway timeout and succeeds when Airtable recovers" do
      stub_request(:post, sync_url).to_return(
        { status: 504, body: "<html>504 Gateway Time-out</html>" },
        { status: 200, body: '{"success":true}' }
      )

      expect(client.post_sync_csv("tblTest", "sncTest", "a,b\n")).to eq("success" => true)
      expect(WebMock).to have_requested(:post, sync_url).twice
    end

    it "raises ServerError when the 5xx outlives the retries" do
      stub_request(:post, sync_url).to_return(status: 504, body: "<html>504 Gateway Time-out</html>")

      expect { client.post_sync_csv("tblTest", "sncTest", "a,b\n") }
        .to raise_error(Airtable::ServerError, /HTTP 504/)
      expect(WebMock).to have_requested(:post, sync_url).times(4)
    end

    it "URL-encodes the sync id so stray whitespace can't mangle the path" do
      stub_request(:post, "https://api.airtable.com/v0/appTest/tblTest/sync/sncTest%0A")
        .to_return(status: 200, body: '{"success":true}')

      expect(client.post_sync_csv("tblTest", "sncTest\n", "a,b\n")).to eq("success" => true)
    end
  end

  describe "#create_record" do
    it "does not retry a 5xx, because the record may already have been created" do
      stub_request(:post, records_url).to_return(status: 502, body: "")

      expect { client.create_record("Participants", { "Email" => "x@example.com" }) }
        .to raise_error(Airtable::ServerError, "Airtable server error")
      expect(WebMock).to have_requested(:post, records_url).once
    end
  end
end
