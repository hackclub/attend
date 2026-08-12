require "rails_helper"
require_relative "../../../app/services/docuseal/error"

RSpec.describe Docuseal::Client do
  # The client resolves its host, base URL, and API key through
  # Docuseal::HostConfig, which reads credentials.docuseal. Stubbing the
  # credentials rather than HostConfig itself keeps the real cluster-resolution
  # logic under test — there are no docuseal credentials in the test env, so
  # without this every client would build requests against "https://api.".
  let(:credentials) do
    {
      default_cluster: "legacy",
      legacy: { host: "https://api.docuseal.co", api_key: "legacy_key", webhook_secret: "legacy_secret" },
      selfhosted: { host: "https://sign.selfhosted.test", api_key: "selfhosted_key", webhook_secret: "selfhosted_secret" }
    }
  end

  # New records are pinned to the self-hosted cluster, so that is where a
  # host-less client lands.
  let(:base_url) { "https://sign.selfhosted.test" }
  let(:api_key) { "selfhosted_key" }
  let(:client) { described_class.new }

  before do
    allow(Rails.application.credentials).to receive(:docuseal).and_return(credentials)
  end

  describe "#initialize" do
    it "takes its host from the pinned self-hosted cluster" do
      expect(client.host).to eq("sign.selfhosted.test")
    end

    it "resolves a legacy host to the legacy cluster, stripping the api. prefix" do
      expect(described_class.new(host: "docuseal.co").host).to eq("docuseal.co")
    end

    it "raises naming the host when that cluster has no API key" do
      credentials[:selfhosted] = { host: "https://sign.selfhosted.test", api_key: nil }

      expect { described_class.new }
        .to raise_error(ArgumentError, "Docuseal API key is required for host sign.selfhosted.test")
    end

    it "prefers an explicitly passed base URL and key over the resolved cluster" do
      stub = stub_request(:get, "https://override.test/submissions/1")
        .with(headers: { "X-Auth-Token" => "override_key" })
        .to_return(status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" })

      described_class.new(api_key: "override_key", base_url: "https://override.test").get_submission(1)

      expect(stub).to have_been_requested
    end
  end

  describe ".for" do
    it "binds to the host stored on the record" do
      record = Struct.new(:docuseal_host).new("docuseal.co")

      expect(described_class.for(record).host).to eq("docuseal.co")
    end

    it "falls back to the default host for a record with no host" do
      record = Struct.new(:docuseal_host).new(nil)

      expect(described_class.for(record).host).to eq("sign.selfhosted.test")
    end
  end

  describe "#create_submission" do
    let(:template_id) { 12345 }
    let(:submitters) do
      [
        { email: "test@example.com", name: "Test User", role: "Signer" }
      ]
    end

    it "makes a POST request to create a submission" do
      stub_request(:post, "#{base_url}/submissions")
        .with(
          headers: { "X-Auth-Token" => api_key, "Content-Type" => "application/json" },
          body: hash_including(template_id: template_id)
        )
        .to_return(
          status: 200,
          body: { id: 1, submitters: [ { slug: "abc123" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = client.create_submission(template_id: template_id, submitters: submitters)

      expect(result["id"]).to eq(1)
      expect(result["submitters"].first["slug"]).to eq("abc123")
    end

    it "sends the request to the record's own cluster" do
      stub_request(:post, "https://api.docuseal.co/submissions")
        .with(headers: { "X-Auth-Token" => "legacy_key" })
        .to_return(status: 200, body: { id: 7 }.to_json, headers: { "Content-Type" => "application/json" })

      legacy = described_class.new(host: "docuseal.co")

      expect(legacy.create_submission(template_id: template_id, submitters: submitters)["id"]).to eq(7)
    end

    it "raises ValidationError on 422 response" do
      stub_request(:post, "#{base_url}/submissions")
        .to_return(
          status: 422,
          body: { error: "Invalid template" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.create_submission(template_id: template_id, submitters: submitters) }
        .to raise_error(Docuseal::ValidationError, "Invalid template")
    end

    it "raises RateLimitError on 429 response" do
      stub_request(:post, "#{base_url}/submissions")
        .to_return(status: 429, body: {}.to_json, headers: { "Content-Type" => "application/json" })

      expect { client.create_submission(template_id: template_id, submitters: submitters) }
        .to raise_error(Docuseal::RateLimitError)
    end

    it "raises AuthenticationError on 401 response" do
      stub_request(:post, "#{base_url}/submissions")
        .to_return(status: 401, body: {}.to_json, headers: { "Content-Type" => "application/json" })

      expect { client.create_submission(template_id: template_id, submitters: submitters) }
        .to raise_error(Docuseal::AuthenticationError)
    end
  end

  describe "#get_submission" do
    it "fetches a submission by ID" do
      stub_request(:get, "#{base_url}/submissions/123")
        .with(headers: { "X-Auth-Token" => api_key })
        .to_return(
          status: 200,
          body: { id: 123, status: "completed" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = client.get_submission(123)

      expect(result["id"]).to eq(123)
      expect(result["status"]).to eq("completed")
    end

    it "raises NotFoundError on 404 response" do
      stub_request(:get, "#{base_url}/submissions/999")
        .to_return(status: 404, body: {}.to_json, headers: { "Content-Type" => "application/json" })

      expect { client.get_submission(999) }.to raise_error(Docuseal::NotFoundError)
    end
  end
end
