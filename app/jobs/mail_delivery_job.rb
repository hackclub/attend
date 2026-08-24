# Used for all `deliver_later` sends (config.action_mailer.delivery_job).
#
# Postmark permanently rejects sends to suppressed addresses, so retrying or
# surfacing the error as an incident is useless — the address itself is the
# problem. Flag the owning Participant/Guardian so admins see it and manual
# sends refuse early, then drop the job.
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  discard_on Postmark::InactiveRecipientError do |job, error|
    mailer, action = job.arguments
    if error.recipients.blank?
      Rails.logger.error("[MailDeliveryJob] Discarded #{mailer}##{action}: inactive recipient, but none parsed from: #{error.message}")
    else
      flagged = Participant.mark_email_undeliverable!(error.recipients) +
        Guardian.mark_email_undeliverable!(error.recipients)
      Rails.logger.warn("[MailDeliveryJob] Discarded #{mailer}##{action}: inactive recipients #{error.recipients.join(', ')} (#{flagged} records flagged)")
    end
  end
end
