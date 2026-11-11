# Runs in the background so a request for a number we hold takes as long as
# one for a number we don't: the portal center must not reveal which phone
# numbers belong to guardians.
class StartGuardianPortalVerificationJob < ApplicationJob
  queue_as :default

  def perform(phone, channel)
    TwilioVerifyService.new.start(to: phone, channel: channel)
  rescue TwilioVerifyService::Error => e
    Rails.logger.error("[GuardianPortalVerification] #{e.message}")
  end
end
