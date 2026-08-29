class AutomatedSmsLog < ApplicationRecord
  include NormalizesPhoneNumbers
  self.implicit_order_column = "created_at"

  encrypts :body

  validates :phone_number, presence: true

  # `for_phone` is an exact match against an E.164 number held elsewhere,
  # so the stored value has to be canonical too.
  normalizes_phone_number :phone_number
  validates :body, presence: true
  validates :sent_at, presence: true

  scope :for_phone, ->(phone) { where(phone_number: phone) }
end
