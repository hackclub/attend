class PushToken < ApplicationRecord
  belongs_to :user

  validates :token, presence: true, uniqueness: true
  validates :platform, inclusion: { in: %w[ios android expo] }, allow_nil: true

  scope :expo_tokens, -> { where("token LIKE 'ExponentPushToken%'") }
  scope :for_users, ->(users) { where(user: users) }
end
