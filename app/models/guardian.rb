class Guardian < ApplicationRecord
  include EmailDeliverability

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
  # A guardian who shares the participant's address gets the participant's
  # invite links, waiver copies and portal codes -- and a minor can sign their
  # own consent by reading their "guardian's" mail. Only checked when the email
  # actually changes, so pre-existing rows can still be edited otherwise.
  validate :email_differs_from_participants, if: :will_save_change_to_email?

  before_validation :normalize_phone

  def full_name
    "#{legal_first_name} #{legal_last_name}"
  end

  private

  def email_differs_from_participants
    return if email.blank? || new_record?

    conflict = participants.where("LOWER(participants.email) = ?", email.strip.downcase).exists?
    return unless conflict

    errors.add(:email, "cannot be the same as the participant's email address")
  end

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
