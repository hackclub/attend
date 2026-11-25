# A number a Person can be reached on, in E.164.
#
# A phone number never identifies anyone: families share them and carriers
# recycle them. So nothing here is unique across people, verified or not, and
# nothing should ever look a person up by number alone.
class PhoneNumber < ApplicationRecord
  include NormalizesPhoneNumbers

  self.implicit_order_column = "created_at"

  SOURCES = %w[user training_profile participant guardian].freeze

  # Deterministic, like participants.phone and guardians.phone, so the same
  # number can be found again for one person.
  encrypts :number, deterministic: true

  belongs_to :person

  validates :number, presence: true, e164_phone: true, uniqueness: { scope: :person_id }
  validates :source, inclusion: { in: SOURCES }

  normalizes_phone_number :number

  scope :verified, -> { where.not(verified_at: nil) }

  def verified?
    verified_at.present?
  end
end
