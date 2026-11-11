require "rails_helper"

RSpec.describe WhatsappSmsFallback do
  let(:twilio) { instance_double(TwilioService) }
  let!(:log) do
    AutomatedSmsLog.create!(phone_number: "+447911123456", body: "Plain text version", channel: "whatsapp",
                            twilio_sid: "SMwa1", sms_fallback_body: "Plain text version",
                            source: "Incident reports", sent_at: Time.current)
  end

  before do
    allow(TwilioService).to receive(:new).and_return(twilio)
    allow(twilio).to receive(:send_sms).and_return({ sid: "SMsms1", status: "queued", channel: "sms" })
  end

  it "resends a failed WhatsApp message as SMS and remembers why it failed" do
    described_class.call(message_sid: "SMwa1", status: "undelivered", error_code: "63003")

    expect(twilio).to have_received(:send_sms).with(to: "+447911123456", body: "Plain text version", source: "Incident reports")
    expect(log.reload).to have_attributes(error_code: "63003", fell_back_at: be_present)
    expect(AutomatedSmsLog.whatsapp_unavailable?("+447911123456")).to be(true)
  end

  it "only resends once when Twilio reports the failure twice" do
    described_class.call(message_sid: "SMwa1", status: "failed", error_code: "63003")
    described_class.call(message_sid: "SMwa1", status: "undelivered", error_code: "63003")

    expect(twilio).to have_received(:send_sms).once
  end

  it "ignores messages that went through" do
    described_class.call(message_sid: "SMwa1", status: "delivered", error_code: nil)

    expect(twilio).not_to have_received(:send_sms)
  end

  it "ignores WhatsApp messages that have no SMS version, like replies" do
    log.update!(sms_fallback_body: nil)

    described_class.call(message_sid: "SMwa1", status: "failed", error_code: "63016")

    expect(twilio).not_to have_received(:send_sms)
  end

  it "ignores SMS messages" do
    log.update!(channel: "sms")

    described_class.call(message_sid: "SMwa1", status: "failed", error_code: "30003")

    expect(twilio).not_to have_received(:send_sms)
  end

  context "for a broadcast" do
    let(:event) { create(:event) }
    let(:message) do
      Message.create!(event: event, audience: "confirmed_attendees", channels: %w[sms], subject: "Update",
                      body: "Hello", sent_by_user: create(:user))
    end
    let(:delivery) do
      message.message_deliveries.create!(participant_event: create(:participant_event, event: event), channel: "sms", recipient_phone: "+447911123456",
                                         status: "delivered", external_id: "SMwa1")
    end

    before { log.update!(message_delivery: delivery) }

    it "points the delivery at the SMS" do
      described_class.call(message_sid: "SMwa1", status: "failed", error_code: "63003")

      expect(delivery.reload.external_id).to eq("SMsms1")
    end

    it "marks the delivery failed when the SMS fails too" do
      allow(twilio).to receive(:send_sms).and_raise(TwilioService::Error, "unreachable")

      described_class.call(message_sid: "SMwa1", status: "failed", error_code: "63003")

      expect(delivery.reload).to have_attributes(status: "failed", error_message: a_string_including("63003", "unreachable"))
    end
  end
end
