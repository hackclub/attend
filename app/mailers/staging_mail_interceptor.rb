# Fails closed on outbound email in staging: every recipient is replaced with
# STAGING_MAIL_RECIPIENT, and if that is not set the delivery is dropped
# entirely rather than sent to whoever the record happens to name.
class StagingMailInterceptor
  class << self
    def delivering_email(message)
      original = Array(message.to) + Array(message.cc) + Array(message.bcc)
      redirect_to = ENV["STAGING_MAIL_RECIPIENT"].presence

      message.cc = nil
      message.bcc = nil

      if redirect_to
        message.to = redirect_to
        message.subject = "[staging → #{original.join(", ")}] #{message.subject}"
      else
        message.to = nil
        message.perform_deliveries = false
        Rails.logger.info(
          "[staging] dropped mail #{message.subject.inspect} for #{original.join(", ")} " \
          "(set STAGING_MAIL_RECIPIENT to receive it)"
        )
      end
    end
  end
end
