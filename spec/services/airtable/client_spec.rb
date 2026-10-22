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

  describe "rate limiting" do
    let(:list_url) { "https://api.airtable.com/v0/appTest/tblTest" }
    let(:retry_sleeps) { [] }

    before do
      allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep) { |_, seconds| retry_sleeps << seconds }
    end

    it "waits out Airtable's 30-second penalty and retries a 429" do
      stub_request(:get, list_url).to_return(
        { status: 429, body: '{"errors":[{"error":"RATE_LIMIT_REACHED"}]}' },
        { status: 200, body: '{"records":[]}' }
      )

      expect(client.list_records("tblTest")).to eq("records" => [])
      expect(retry_sleeps).to eq([ 30.0 ])
    end

    it "waits as long as Retry-After asks when that is longer" do
      stub_request(:get, list_url).to_return(
        { status: 429, headers: { "Retry-After" => "45" }, body: "" },
        { status: 200, body: '{"records":[]}' }
      )

      client.list_records("tblTest")

      expect(retry_sleeps).to eq([ 45.0 ])
    end

    it "gives up straight away when Retry-After is beyond the cap" do
      stub_request(:get, list_url).to_return(status: 429, headers: { "Retry-After" => "600" }, body: "")

      expect { client.list_records("tblTest") }.to raise_error(Airtable::RateLimitError)
      expect(WebMock).to have_requested(:get, list_url).once
      expect(retry_sleeps).to be_empty
    end

    it "does not wait out a 5xx Retry-After beyond the cap either" do
      stub_request(:get, list_url).to_return(status: 503, headers: { "Retry-After" => "1800" }, body: "")

      expect { client.list_records("tblTest") }.to raise_error(Airtable::ServerError)
      expect(retry_sleeps).to be_empty
    end

    it "raises RateLimitError once the retries run out" do
      stub_request(:get, list_url).to_return(status: 429, body: "")

      expect { client.list_records("tblTest") }.to raise_error(Airtable::RateLimitError)
      expect(WebMock).to have_requested(:get, list_url).times(3)
    end

    # Unlike a 5xx, a 429 means Airtable refused the request without running it.
    it "retries a refused create, which a 5xx never does" do
      stub_request(:post, records_url).to_return(
        { status: 429, body: "" },
        { status: 200, body: '{"id":"recNew"}' }
      )

      expect(client.create_record("Participants", { "Email" => "x@example.com" })).to eq("id" => "recNew")
      expect(WebMock).to have_requested(:post, records_url).twice
    end
  end

  it "raises ForbiddenError on a 403" do
    stub_request(:post, sync_url)
      .to_return(status: 403, body: '{"error":{"type":"INVALID_PERMISSIONS","message":"Invalid external table sync ID"}}')

    expect { client.post_sync_csv("tblTest", "sncTest", "a,b\n") }
      .to raise_error(Airtable::ForbiddenError, "HTTP 403: INVALID_PERMISSIONS: Invalid external table sync ID")
  end
end
