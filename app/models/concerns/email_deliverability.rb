# Tracks whether a record's email address is known-undeliverable. Postmark
# suppresses an address after a hard bounce or spam complaint and rejects all
# later sends to it (Postmark::InactiveRecipientError), so once flagged the
# usual remedy is correcting the address, which clears the flag automatically.
# Global admins can also clear it by hand (Admin::ParticipantsController
# #clear_email_bounce) for a flag that's wrong or stale.
module EmailDeliverability
  extend ActiveSupport::Concern

  # URI::MailTo::EMAIL_REGEXP accepts a bare host ("someone@hotmail"), which
  # Postmark refuses outright as an invalid To address. Require a dotted domain
  # ending in a top-level part of two or more letters.
  DOMAIN_WITH_TLD = /@[^@\s]+\.(?:\p{L}{2,}|xn--[a-z0-9-]+)\z/i

  included do
    before_save :clear_email_undeliverable_flag, if: :will_save_change_to_email?
    # Only when the address changes, so rows saved before this check stay
    # editable; a bad one gets flagged by MailDeliveryJob on its first send.
    validate :email_has_top_level_domain, if: :will_save_change_to_email?

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

  def email_has_top_level_domain
    # blank or otherwise malformed addresses are the format validation's to report
    return if email.blank? || !email.to_s.match?(URI::MailTo::EMAIL_REGEXP)
    return if email.to_s.strip.match?(DOMAIN_WITH_TLD)

    # typed :invalid so forms that map error types show their usual wording
    errors.add(:email, :invalid, message: "is missing the part after the dot, like .com")
  end

  def clear_email_undeliverable_flag
    self.email_undeliverable_at = nil unless will_save_change_to_email_undeliverable_at?
  end
end
