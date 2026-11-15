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
        body: "redacted body\n\nReply STOP to opt out",
        twilio_sid: "SM200",
        source: "Guardian portal",
        channel: "sms"
      )

      service.send_sms(to: "+14155551234", body: "real body", log_body: "redacted body", source: "Guardian portal")
    end

    it "records the actual body when no log body is given" do
      expect(Support::RecordAutomatedSms).to receive(:call).with(
        phone: "+14155551234",
        body: "hello\n\nReply STOP to opt out",
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
      expect(posted.last).to include("To" => "+14155551234", "From" => "+15075550100", "Body" => "Plain text version\n\nReply STOP to opt out")
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

  describe "#send_sms routing" do
    subject(:service) { described_class.new(account_sid: "AC123", auth_token: "token", from_number: "+15075550100") }

    let(:posted) { [] }
    let(:failure) { nil }

    before do
      allow(Setting).to receive(:twilio_enabled?).and_return(true)
      connection = instance_double(Faraday::Connection)
      allow(connection).to receive(:post) do |_path, &block|
        request = Struct.new(:body).new
        block.call(request)
        posted << URI.decode_www_form(request.body).to_h
        if failure
          instance_double(Faraday::Response, success?: false, status: 400, body: failure.to_json)
        else
          instance_double(Faraday::Response, success?: true, body: { sid: "SM#{posted.size}", status: "queued" }.to_json)
        end
      end
      allow(service).to receive(:connection).and_return(connection)
    end

    it "texts +1 numbers from the long code and asks for status callbacks" do
      service.send_sms(to: "+14155551234", body: "hi")

      expect(posted.last).to include("From" => "+15075550100", "StatusCallback" => a_string_ending_with("/twilio/status"))
    end

    it "texts countries where the long code delivers from the long code" do
      service.send_sms(to: "+919876543210", body: "hi")

      expect(posted.last["From"]).to eq("+15075550100")
    end

    it "texts the UK from the Hack Club sender" do
      service.send_sms(to: "+447911123456", body: "hi")

      expect(posted.last["From"]).to eq("Hack Club")
    end

    it "skips countries we have no working sender for" do
      result = service.send_sms(to: "+923001234567", body: "hi")

      expect(result).to include(skipped: true)
      expect(posted).to be_empty
    end

    it "skips a number whose last text failed for good" do
      SmsSuppression.record(phone: "+14155551234", error_code: "21610")

      expect(service.send_sms(to: "+14155551234", body: "hi")).to include(skipped: true)
      expect(posted).to be_empty
    end

    it "texts that number again once the suppression runs out" do
      SmsSuppression.record(phone: "+14155551234", error_code: "21610")
      SmsSuppression.update_all(failed_at: 31.days.ago)

      service.send_sms(to: "+14155551234", body: "hi")

      expect(posted.size).to eq(1)
    end

    context "when Twilio rejects the send for good" do
      let(:failure) { { code: 21612, message: "cannot be sent with the current combination of To and From" } }

      it "raises with the code and suppresses the number" do
        expect { service.send_sms(to: "+14155551234", body: "hi") }
          .to raise_error(TwilioService::Error) { |e| expect(e.code).to eq("21612") }
        expect(SmsSuppression.active?("+14155551234")).to be(true)
      end
    end

    context "when Twilio rejects the send for a passing reason" do
      let(:failure) { { code: 20429, message: "Too many requests" } }

      it "does not suppress the number" do
        expect { service.send_sms(to: "+14155551234", body: "hi") }.to raise_error(TwilioService::Error)
        expect(SmsSuppression.active?("+14155551234")).to be(false)
      end
    end
  end

  describe "opt-outs" do
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

    it "tells long-code recipients to reply STOP" do
      service.send_sms(to: "+14155551234", body: "Doors open at 9")

      expect(posted.last["Body"]).to eq("Doors open at 9\n\nReply STOP to opt out")
    end

    it "gives Hack Club sender recipients a link, since they can't reply" do
      service.send_sms(to: "+447911123456", body: "Doors open at 9")

      expect(posted.last["Body"]).to match(%r{\n\nStop texts: https://[^/\s]+/stop/#{SmsOptOut.token_for("+447911123456")}\z})
    end

    it "sends nothing, by SMS or WhatsApp, to someone who opted out" do
      SmsOptOut.opt_out!("+447911123456", source: :link)
      SmsOptOut.opt_out!("+14155551234", source: :keyword)

      expect(service.send_message(to: "+447911123456", sms_body: "x", whatsapp_template: "HX1")).to include(skipped: true)
      expect(service.send_sms(to: "+14155551234", body: "x")).to include(skipped: true)
      expect(posted).to be_empty
    end
  end
end
