# Every automated text we send, by SMS or WhatsApp, so support agents can see
# it in chat history. WhatsApp rows also carry the SMS to resend if WhatsApp
# fails, and remember numbers that turned out not to be on WhatsApp.
class AutomatedSmsLog < ApplicationRecord
  include NormalizesPhoneNumbers
  self.implicit_order_column = "created_at"

  # Twilio errors meaning the number isn't on WhatsApp at all, as opposed to
  # a one-off delivery failure.
  NOT_ON_WHATSAPP_ERRORS = %w[63003 63024].freeze

  # How long a number that wasn't on WhatsApp stays on SMS before we try again.
  WHATSAPP_RETRY_AFTER = 180.days

  belongs_to :message_delivery, optional: true

  encrypts :body, :sms_fallback_body

  enum :channel, { sms: "sms", whatsapp: "whatsapp" }, default: "sms"

  validates :phone_number, presence: true

  # `for_phone` is an exact match against an E.164 number held elsewhere,
  # so the stored value has to be canonical too.
  normalizes_phone_number :phone_number
  validates :body, presence: true
  validates :sent_at, presence: true

  scope :for_phone, ->(phone) { where(phone_number: phone) }

  def self.whatsapp_unavailable?(phone)
    whatsapp.for_phone(phone)
            .where(error_code: NOT_ON_WHATSAPP_ERRORS, sent_at: WHATSAPP_RETRY_AFTER.ago..)
            .exists?
  end
end
