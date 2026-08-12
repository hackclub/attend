module EmailLogging
  extend ActiveSupport::Concern

  included do
    after_action :log_email_delivery
  end

  private

  def log_email_delivery
    @email_log_metadata ||= {}
  end

  def set_email_log_metadata(emailable: nil, event: nil)
    @email_log_metadata = { emailable: emailable, event: event }
  end
end
