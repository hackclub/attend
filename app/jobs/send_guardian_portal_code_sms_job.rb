class SendGuardianPortalCodeSmsJob < ApplicationJob
  queue_as :default

  def perform(phone, code)
    TwilioService.new.send_sms(
      to: phone,
      body: "Your Attend verification code is #{code}. It expires in 10 minutes.",
      log_body: "Your Attend verification code is [redacted]. It expires in 10 minutes.",
      source: "Guardian portal"
    )
  end
end
