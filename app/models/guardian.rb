class Guardian < ApplicationRecord
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
  validates :phone, phone: { possible: true, allow_blank: true }

  before_validation :normalize_phone

  def full_name
    "#{legal_first_name} #{legal_last_name}"
  end

  private

  def normalize_phone
    return if phone.blank?

    if phone.start_with?("+")
      parsed = Phonelib.parse(phone)
      self.phone = parsed.e164 if parsed.valid?
    else
      parsed = Phonelib.parse(phone, nil)
      self.phone = parsed.e164 if parsed.valid?
    end
  end
end
