# A number we've stopped texting for a while because SMS failed in a way
# that would fail again (see CreateSmsSuppressions). Expires on its own, so a
# fixed sender setup or a re-subscribed number gets tried again later.
class SmsSuppression < ApplicationRecord
  self.implicit_order_column = "created_at"

  # Twilio error codes that say the next text will fail the same way.
  #   21211 invalid number            21408 country switched off (geo permissions)
  #   21610 replied STOP              21612 can't route from our sender to this number
  #   21614 not a mobile number       30005 unknown or inactive number
  #   30006 landline or unreachable carrier
  #   30450 blocked by Twilio's SMS pumping protection
  PERMANENT_ERRORS = %w[21211 21408 21610 21612 21614 30005 30006 30450].freeze

  SUPPRESS_FOR = 30.days

  validates :phone_number, :error_code, :failed_at, presence: true

  def self.permanent?(error_code)
    PERMANENT_ERRORS.include?(error_code.to_s)
  end

  def self.active?(phone)
    where(phone_number: phone, failed_at: SUPPRESS_FOR.ago..).exists?
  end

  # Returns the suppression, or nil when the error isn't a permanent one.
  def self.record(phone:, error_code:)
    return unless phone.present? && permanent?(error_code)

    upsert({ phone_number: phone, error_code: error_code.to_s, failed_at: Time.current },
           unique_by: :phone_number, update_only: %i[error_code failed_at])
  end
end
