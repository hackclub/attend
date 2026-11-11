require "rails_helper"

RSpec.describe TwilioVerifyService do
  subject(:service) { described_class.new(service_sid: "VA#{"0" * 32}", account_sid: "AC123", auth_token: "token") }

  let(:verifications) { double("verifications") }
  let(:verification_checks) { double("verification_checks") }

  before do
    twilio_service = double("service", verifications: verifications, verification_checks: verification_checks)
    allow(service).to receive(:service).and_return(twilio_service)
  end

  def rest_error(code)
    response = Twilio::Response.new(404, { "code" => code, "message" => "Error #{code}" }.to_json)
    Twilio::REST::RestError.new("Error #{code}", response)
  end

  describe ".default_channel_for" do
    it "uses SMS for everyone while WhatsApp is off" do
      allow(Setting).to receive(:twilio_verify_whatsapp?).and_return(false)

      expect(described_class.default_channel_for("+447700900123")).to eq("sms")
    end

    it "uses WhatsApp outside +1 once switched on" do
      allow(Setting).to receive(:twilio_verify_whatsapp?).and_return(true)

      expect(described_class.default_channel_for("+447700900123")).to eq("whatsapp")
      expect(described_class.default_channel_for("+12025550123")).to eq("sms")
      expect(described_class.default_channel_for("+14165550123")).to eq("sms")
    end
  end

  describe ".available?" do
    it "needs Twilio switched on and a service SID" do
      allow(Setting).to receive(:twilio_enabled?).and_return(true)
      allow(Setting).to receive(:twilio_verify_service_sid).and_return(nil)

      expect(described_class.available?).to be(false)
    end
  end

  describe "#start" do
    it "starts a verification on the requested channel" do
      expect(verifications).to receive(:create).with(to: "+447700900123", channel: "whatsapp")

      expect(service.start(to: "+447700900123", channel: "whatsapp")).to eq("whatsapp")
    end

    it "falls back to SMS when Twilio rejects the WhatsApp send" do
      expect(verifications).to receive(:create).with(to: "+447700900123", channel: "whatsapp").and_raise(rest_error(60200))
      expect(verifications).to receive(:create).with(to: "+447700900123", channel: "sms")

      expect(service.start(to: "+447700900123", channel: "whatsapp")).to eq("sms")
    end

    it "raises a service error when the SMS send fails" do
      allow(verifications).to receive(:create).and_raise(rest_error(60203))

      expect { service.start(to: "+12025550123") }.to raise_error(TwilioVerifyService::Error, /60203/)
    end

    it "refuses unknown channels" do
      expect { service.start(to: "+12025550123", channel: "call") }.to raise_error(ArgumentError)
    end

    it "refuses to send without a service SID" do
      unconfigured = described_class.new(service_sid: "", account_sid: "AC123", auth_token: "token")
      allow(Setting).to receive(:twilio_verify_service_sid).and_return(nil)

      expect { unconfigured.start(to: "+12025550123") }.to raise_error(TwilioVerifyService::Error, /not configured/)
    end
  end

  describe "#check" do
    it "is true when Twilio approves the code" do
      allow(verification_checks).to receive(:create).with(to: "+12025550123", code: "123456")
        .and_return(double(status: "approved"))

      expect(service.check(to: "+12025550123", code: "123456")).to be(true)
    end

    it "is false for a wrong code" do
      allow(verification_checks).to receive(:create).and_return(double(status: "pending"))

      expect(service.check(to: "+12025550123", code: "000000")).to be(false)
    end

    it "is false when the verification expired or never existed" do
      allow(verification_checks).to receive(:create).and_raise(rest_error(20404))

      expect(service.check(to: "+12025550123", code: "123456")).to be(false)
    end

    it "raises on other Twilio errors" do
      allow(verification_checks).to receive(:create).and_raise(rest_error(20003))

      expect { service.check(to: "+12025550123", code: "123456") }.to raise_error(TwilioVerifyService::Error, /20003/)
    end
  end
end
