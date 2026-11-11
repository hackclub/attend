require "rails_helper"

RSpec.describe StartGuardianPortalVerificationJob do
  it "starts a Twilio Verify verification on the given channel" do
    expect_any_instance_of(TwilioVerifyService).to receive(:start).with(to: "+447700900123", channel: "whatsapp")

    described_class.perform_now("+447700900123", "whatsapp")
  end

  it "logs instead of raising when Twilio Verify fails, so the job doesn't retry and resend" do
    allow_any_instance_of(TwilioVerifyService).to receive(:start).and_raise(TwilioVerifyService::Error, "Twilio Verify error 60203: Max send attempts reached")
    expect(Rails.logger).to receive(:error).with(/60203/)

    expect { described_class.perform_now("+12025550123", "sms") }.not_to raise_error
  end
end
