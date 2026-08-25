require "rails_helper"

RSpec.describe TurnstileVerifier do
  let(:token) { "0.token" }

  def stub_siteverify(body)
    stub_request(:post, described_class::VERIFY_URL)
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  before do
    allow(described_class).to receive(:secret_key).and_return("0x-secret")
    allow(described_class).to receive(:expected_hostnames).and_return(Set["staging.attend.hackclub.com"])
  end

  describe ".verify" do
    it "passes a successful token from an expected hostname" do
      stub_siteverify("success" => true, "hostname" => "staging.attend.hackclub.com")

      expect(described_class.verify(token)).to be true
    end

    it "rejects an unsuccessful token" do
      stub_siteverify("success" => false, "error-codes" => [ "timeout-or-duplicate" ])

      expect(described_class.verify(token)).to be false
    end

    it "rejects a blank token without calling siteverify" do
      expect(described_class.verify(nil)).to be false
      expect(a_request(:post, described_class::VERIFY_URL)).not_to have_been_made
    end

    it "rejects an over-long token without calling siteverify" do
      expect(described_class.verify("a" * (described_class::MAX_TOKEN_LENGTH + 1))).to be false
      expect(a_request(:post, described_class::VERIFY_URL)).not_to have_been_made
    end

    it "rejects a token solved for a different action" do
      stub_siteverify(
        "success" => true,
        "hostname" => "staging.attend.hackclub.com",
        "action" => "incident_report"
      )

      expect(described_class.verify(token, action: "guardian_portal_code")).to be false
    end

    it "accepts a token whose action matches" do
      stub_siteverify(
        "success" => true,
        "hostname" => "staging.attend.hackclub.com",
        "action" => "guardian_portal_code"
      )

      expect(described_class.verify(token, action: "guardian_portal_code")).to be true
    end

    it "rejects a token solved on another hostname sharing the sitekey" do
      stub_siteverify("success" => true, "hostname" => "attacker.example.com")

      expect(described_class.verify(token)).to be false
    end

    it "rejects rather than raising when siteverify is unreachable" do
      stub_request(:post, described_class::VERIFY_URL).to_timeout

      expect(described_class.verify(token)).to be false
    end

    it "rejects when siteverify returns unparseable data" do
      stub_request(:post, described_class::VERIFY_URL).to_return(status: 502, body: "<html>bad gateway</html>")

      expect(described_class.verify(token)).to be false
    end
  end

  describe "when no secret is configured" do
    before { allow(described_class).to receive(:secret_key).and_return(nil) }

    it "skips verification in local development" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))

      expect(described_class.verify(nil)).to be true
    end

    # The whole point of the hardening: an unconfigured deployed environment must
    # not wave every request through the challenge.
    it "fails closed in a deployed environment" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("staging"))

      expect(described_class.verify(token)).to be false
    end
  end

  describe ".expected_hostnames" do
    before { allow(described_class).to receive(:expected_hostnames).and_call_original }

    it "uses TURNSTILE_HOSTNAMES when set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TURNSTILE_HOSTNAMES").and_return("a.example.com, b.example.com")

      expect(described_class.expected_hostnames).to eq(Set["a.example.com", "b.example.com"])
    end

    it "falls back to APP_HOST" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TURNSTILE_HOSTNAMES").and_return(nil)
      allow(ENV).to receive(:[]).with("APP_HOST").and_return("staging.attend.hackclub.com")

      expect(described_class.expected_hostnames).to include("staging.attend.hackclub.com")
    end
  end
end
