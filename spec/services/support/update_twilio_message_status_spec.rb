require "rails_helper"

RSpec.describe Support::UpdateTwilioMessageStatus do
  let!(:log) do
    AutomatedSmsLog.create!(phone_number: "+14155551234", body: "Doors open at 9", channel: "sms",
                            twilio_sid: "SMsms1", sent_at: Time.current)
  end

  def callback(status:, error_code:)
    described_class.call("MessageSid" => "SMsms1", "MessageStatus" => status, "ErrorCode" => error_code)
  end

  it "stops texting a number after a permanent failure" do
    callback(status: "undelivered", error_code: "30006")

    expect(SmsSuppression.active?("+14155551234")).to be(true)
  end

  it "keeps texting a number after a passing failure" do
    callback(status: "undelivered", error_code: "30003")

    expect(SmsSuppression.active?("+14155551234")).to be(false)
  end

  it "ignores delivered messages" do
    callback(status: "delivered", error_code: nil)

    expect(SmsSuppression.count).to eq(0)
  end

  it "ignores failures on WhatsApp messages" do
    log.update!(channel: "whatsapp")

    callback(status: "failed", error_code: "21612")

    expect(SmsSuppression.count).to eq(0)
  end
end
