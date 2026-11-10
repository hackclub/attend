# Used for all `deliver_later` sends (config.action_mailer.delivery_job).
#
# Postmark permanently rejects sends to suppressed addresses, so retrying or
# surfacing the error as an incident is useless — the address itself is the
# problem. Flag the owning Participant/Guardian so admins see it and manual
# sends refuse early, then drop the job.
class MailDeliveryJob < ActionMailer::MailDeliveryJob
  # Postmark's "Invalid 'To' address: 'someone@nowhere'." (error code 300).
  # The same error class covers other malformed-request problems, which are
  # bugs on our side and still raise.
  INVALID_RECIPIENT_MESSAGE = /Invalid '(?:To|Cc|Bcc)' address: '([^']*)'/i

  # The record the mail was about (usually a registration) was deleted between
  # enqueue and send, so there's nothing left to send about.
  discard_on ActiveJob::DeserializationError do |job, error|
    mailer, action = job.serialized_arguments || job.arguments
    Rails.logger.warn("[MailDeliveryJob] Discarded #{mailer}##{action}: #{error.cause&.class || error.class} while loading its arguments")
  end

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

  rescue_from Postmark::InvalidEmailRequestError do |error|
    recipients = self.class.invalid_recipients(error.message)
    raise error if recipients.empty?

    mailer, action = arguments
    flagged = Participant.mark_email_undeliverable!(recipients) +
      Guardian.mark_email_undeliverable!(recipients)
    Rails.logger.warn("[MailDeliveryJob] Discarded #{mailer}##{action}: malformed recipient address (#{flagged} records flagged)")
  end

  def self.invalid_recipients(message)
    message.to_s.scan(INVALID_RECIPIENT_MESSAGE).flatten
      .flat_map { |list| list.scan(/[^\s,;<>"]+@[^\s,;<>"]*/) }
      .uniq
  end
end
