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
        source: "Guardian portal",
        channel: "sms"
      )

      service.send_sms(to: "+14155551234", body: "real body", log_body: "redacted body", source: "Guardian portal")
    end

    it "records the actual body when no log body is given" do
      expect(Support::RecordAutomatedSms).to receive(:call).with(
        phone: "+14155551234",
        body: "hello",
        twilio_sid: "SM200",
        source: nil,
        channel: "sms"
      )

      service.send_sms(to: "+14155551234", body: "hello")
    end

    it "does not fail the send when recording raises" do
      allow(Support::RecordAutomatedSms).to receive(:call).and_raise(StandardError, "db down")

      result = service.send_sms(to: "+14155551234", body: "hello")

      expect(result[:sid]).to eq("SM200")
    end
  end

  describe "#send_message" do
    subject(:service) { described_class.new(account_sid: "AC123", auth_token: "token", from_number: "+15075550100") }

    let(:posted) { [] }

    before do
      allow(Setting).to receive(:twilio_enabled?).and_return(true)
      allow(Setting).to receive(:whatsapp_enabled?).and_return(true)
      connection = instance_double(Faraday::Connection)
      allow(connection).to receive(:post) do |_path, &block|
        request = Struct.new(:body).new
        block.call(request)
        posted << URI.decode_www_form(request.body).to_h
        instance_double(Faraday::Response, success?: true, body: { sid: "SM#{posted.size}", status: "queued" }.to_json)
      end
      allow(service).to receive(:connection).and_return(connection)
    end

    def send_to(phone)
      service.send_message(to: phone, sms_body: "Plain text version", whatsapp_template: "HXtemplate",
                           whatsapp_variables: { 1 => "Example Hackathon", 2 => "Doors open at 9" }, source: "Broadcast message")
    end

    it "sends a WhatsApp template to numbers outside +1" do
      result = send_to("+447911123456")

      expect(result[:channel]).to eq("whatsapp")
      expect(posted.last).to include(
        "To" => "whatsapp:+447911123456",
        "From" => "whatsapp:+15075550100",
        "ContentSid" => "HXtemplate",
        "StatusCallback" => a_string_ending_with("/twilio/status")
      )
      expect(JSON.parse(posted.last["ContentVariables"])).to eq("1" => "Example Hackathon", "2" => "Doors open at 9")
      expect(posted.last).not_to have_key("Body")
    end

    it "logs the WhatsApp send with the SMS to fall back to" do
      send_to("+447911123456")

      log = AutomatedSmsLog.last
      expect(log).to have_attributes(channel: "whatsapp", content_sid: "HXtemplate",
                                     sms_fallback_body: "Plain text version", body: "Plain text version")
    end

    it "texts +1 numbers" do
      result = send_to("+14155551234")

      expect(result[:channel]).to eq("sms")
      expect(posted.last).to include("To" => "+14155551234", "From" => "+15075550100", "Body" => "Plain text version")
    end

    it "texts everyone while WhatsApp is switched off" do
      allow(Setting).to receive(:whatsapp_enabled?).and_return(false)

      expect(send_to("+447911123456")[:channel]).to eq("sms")
    end

    it "texts a number that recently turned out not to be on WhatsApp" do
      AutomatedSmsLog.create!(phone_number: "+447911123456", body: "x", channel: "whatsapp",
                              error_code: "63003", sent_at: 1.day.ago)

      expect(send_to("+447911123456")[:channel]).to eq("sms")
    end

    it "tries WhatsApp again once that is old news" do
      AutomatedSmsLog.create!(phone_number: "+447911123456", body: "x", channel: "whatsapp",
                              error_code: "63003", sent_at: 200.days.ago)

      expect(send_to("+447911123456")[:channel]).to eq("whatsapp")
    end

    it "keeps using WhatsApp after an unrelated delivery failure" do
      AutomatedSmsLog.create!(phone_number: "+447911123456", body: "x", channel: "whatsapp",
                              error_code: "63016", sent_at: 1.day.ago)

      expect(send_to("+447911123456")[:channel]).to eq("whatsapp")
    end
  end
end
