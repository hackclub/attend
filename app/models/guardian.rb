class Guardian < ApplicationRecord
  include EmailDeliverability
  include NormalizesPhoneNumbers

  has_paper_trail

  self.implicit_order_column = "created_at"

  encrypts :phone, deterministic: true
  encrypts :address_line_1, :address_line_2, :city, :state, :postal_code, :country

  belongs_to :user, optional: true
  has_many :guardian_participant_events, dependent: :destroy
  has_many :participant_events, through: :guardian_participant_events
  has_many :participants, through: :participant_events, source: :participant

  validates :legal_first_name, presence: true
  validates :legal_last_name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :phone, e164_phone: true, allow_blank: true

  normalizes_phone_number :phone

  def full_name
    "#{legal_first_name} #{legal_last_name}"
  end
end
