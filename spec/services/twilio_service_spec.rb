require "rails_helper"

RSpec.describe TwilioService do
  describe "#send_sms" do
    subject(:service) { described_class.new(account_sid: "AC123", auth_token: "token", from_number: "+18005550000") }

    let(:response) do
      instance_double(Faraday::Response, success?: true, body: { sid: "SM200", status: "queued" }.to_json)
    end

    before do
      allow(Setting).to receive(:twilio_enabled?).and_return(true)
      connection = instance_double(Faraday::Connection)
      allow(connection).to receive(:post).and_return(response)
      allow(service).to receive(:connection).and_return(connection)
    end

    it "records the send for support chat history, preferring the redacted log body" do
      expect(Support::RecordAutomatedSms).to receive(:call).with(
        phone: "+14155551234",
        body: "redacted body",
        twilio_sid: "SM200",
        source: "Guardian portal"
      )

      service.send_sms(to: "+14155551234", body: "real body", log_body: "redacted body", source: "Guardian portal")
    end

    it "records the actual body when no log body is given" do
      expect(Support::RecordAutomatedSms).to receive(:call).with(
        phone: "+14155551234",
        body: "hello",
        twilio_sid: "SM200",
        source: nil
      )

      service.send_sms(to: "+14155551234", body: "hello")
    end

    it "does not fail the send when recording raises" do
      allow(Support::RecordAutomatedSms).to receive(:call).and_raise(StandardError, "db down")

      result = service.send_sms(to: "+14155551234", body: "hello")

      expect(result[:sid]).to eq("SM200")
    end
  end
end
