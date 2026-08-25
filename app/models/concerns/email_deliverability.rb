# Tracks whether a record's email address is known-undeliverable. Postmark
# suppresses an address after a hard bounce or spam complaint and rejects all
# later sends to it (Postmark::InactiveRecipientError), so once flagged the
# only remedy is correcting the address — which clears the flag automatically.
module EmailDeliverability
  extend ActiveSupport::Concern

  included do
    before_save :clear_email_undeliverable_flag, if: :will_save_change_to_email?

    scope :email_undeliverable, -> { where.not(email_undeliverable_at: nil) }
  end

  class_methods do
    def mark_email_undeliverable!(addresses)
      normalized = Array(addresses).filter_map { |a| a.to_s.strip.downcase.presence }
      return 0 if normalized.empty?

      where("LOWER(email) IN (?)", normalized)
        .where(email_undeliverable_at: nil)
        .update_all(email_undeliverable_at: Time.current)
    end
  end

  def email_undeliverable?
    email_undeliverable_at.present?
  end

  private

  def clear_email_undeliverable_flag
    self.email_undeliverable_at = nil unless will_save_change_to_email_undeliverable_at?
  end
end
