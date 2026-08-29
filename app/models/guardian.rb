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
  # A guardian who shares the participant's address gets the participant's
  # invite links, waiver copies and portal codes -- and a minor can sign their
  # own consent by reading their "guardian's" mail. Only checked when the email
  # actually changes, so pre-existing rows can still be edited otherwise.
  validate :email_differs_from_participants, if: :will_save_change_to_email?

  normalizes_phone_number :phone

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
end
