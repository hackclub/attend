require "rails_helper"

RSpec.describe BroadcastScreener do
  let(:event) { create(:event, name: "Lantern Hackathon") }

  # Stands in for Anthropic::Client: records the request, returns `verdict`.
  let(:fake_client_class) do
    Class.new do
      attr_reader :requests

      def initialize(verdict: nil, stop_reason: :end_turn, error: nil)
        @verdict, @stop_reason, @error, @requests = verdict, stop_reason, error, []
      end

      def messages = self

      def create(**params)
        @requests << params
        raise @error if @error

        block = Struct.new(:type, :text).new(:text, @verdict.to_json)
        Struct.new(:stop_reason, :content).new(@stop_reason, [ block ])
      end
    end
  end

  def screen(text, client: nil, subject: nil)
    described_class.call(event: event, subject: subject, text: text, client: client)
  end

  describe ".blocked_reasons" do
    it "catches a guardian portal or invite link on any host" do
      token = SecureRandom.urlsafe_base64(32)

      [ "https://attend.example.com/guardian/portal/#{token}", "/guardian/invite/#{token}" ].each do |link|
        expect(described_class.blocked_reasons("Here you go: #{link}")).to contain_exactly(a_string_including("guardian portal link"))
      end
    end

    it "ignores ordinary text and the token-less portal page" do
      expect(described_class.blocked_reasons("Sign in at https://attend.example.com/guardian/portals", nil)).to be_empty
    end
  end

  describe "heuristics" do
    it "flags a promo code without asking Claude" do
      client = fake_client_class.new(verdict: { hold: false, category: "ok", reason: "" })
      result = screen("Use promo code HACK20 for 20% off at our store!", client: client)

      expect(result).to be_flagged
      expect(result.categories).to eq([ "marketing" ])
      expect(result.flagged_by).to eq("heuristics")
      expect(result.reason).to include("promo or discount code")
      expect(client.requests).to be_empty
    end

    it "flags a shortened link and reads the subject too" do
      result = screen("details below", subject: "Claim it at bit.ly/abc123")

      expect(result).to be_flagged
      expect(result.categories).to eq([ "spam" ])
    end

    it "doesn't treat Google Maps share links as shorteners" do
      [ "https://maps.app.goo.gl/AbC123xyz", "https://goo.gl/maps/AbC123xyz" ].each do |link|
        result = screen("The venue is here: #{link}. Doors open at 9am.")

        expect(result).not_to be_flagged, "expected #{link} not to be flagged"
      end
    end

    it "still flags a plain goo.gl short link" do
      expect(screen("Grab yours at https://goo.gl/AbC123")).to be_flagged
    end

    it "lets ordinary logistics through" do
      result = screen("Doors open at 9am on Saturday. Bring a laptop, charger and your ID. Lunch and prizes provided!")

      expect(result).not_to be_flagged
    end
  end

  describe "Claude" do
    it "flags what the model holds, with its category and reason" do
      client = fake_client_class.new(verdict: { hold: true, category: "off_topic", reason: "Announces an unrelated summer camp." })
      result = screen("Sign up for our summer coding camp in July!", client: client)

      expect(result).to be_flagged
      expect(result.categories).to eq([ "off_topic" ])
      expect(result.reason).to eq("Announces an unrelated summer camp.")
      expect(result.flagged_by).to eq("model")
    end

    it "sends the event as context and the text inside broadcast tags, with structured output" do
      client = fake_client_class.new(verdict: { hold: false, category: "ok", reason: "" })
      screen("See you at {{first_name}}'s table", client: client)

      request = client.requests.sole
      expect(request[:model]).to eq("claude-haiku-5-5")
      expect(request[:output_config][:format_][:type]).to eq(:json_schema)
      expect(request[:messages].sole[:content]).to include("Event: Lantern Hackathon", "<broadcast>", "{{first_name}}")
    end

    it "clears a message the model doesn't hold" do
      client = fake_client_class.new(verdict: { hold: false, category: "ok", reason: "" })

      expect(screen("Your flight details are on the dashboard.", client: client)).not_to be_flagged
    end

    it "ignores a hold that names no category" do
      client = fake_client_class.new(verdict: { hold: true, category: "ok", reason: "?" })

      expect(screen("Reminder: waivers are due Friday.", client: client)).not_to be_flagged
    end

    it "fails open when the API errors" do
      client = fake_client_class.new(error: StandardError.new("connection refused"))

      expect(screen("Reminder: waivers are due Friday.", client: client)).not_to be_flagged
    end

    it "fails open when the model refuses" do
      client = fake_client_class.new(verdict: {}, stop_reason: :refusal)

      expect(screen("Reminder: waivers are due Friday.", client: client)).not_to be_flagged
    end

    it "skips the model when no API key is configured" do
      allow(described_class).to receive(:api_key).and_return(nil)
      expect(Anthropic::Client).not_to receive(:new)

      expect(screen("Reminder: waivers are due Friday.")).not_to be_flagged
    end
  end
end
