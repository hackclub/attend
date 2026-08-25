class AutomatedSmsLog < ApplicationRecord
  self.implicit_order_column = "created_at"

  encrypts :body

  validates :phone_number, presence: true
  validates :body, presence: true
  validates :sent_at, presence: true

  scope :for_phone, ->(phone) { where(phone_number: phone) }
end
