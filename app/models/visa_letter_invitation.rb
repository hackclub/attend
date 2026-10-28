# An organiser's invitation to apply for a visa letter. It lets the person
# apply when the event's letters are invite-only or its form has closed, and
# overrides an earlier hard rejection. Unlike Envoy's, using one never throws
# away an application that already has a letter.
class VisaLetterInvitation < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event
  belongs_to :issued_by, class_name: "User", optional: true
  has_one :visa_letter_application, dependent: :nullify

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, presence: true, uniqueness: true
  validate :email_not_banned, on: :create

  before_validation :normalize_email
  before_validation :generate_token, on: :create

  scope :unclaimed, -> { where(claimed_at: nil) }
  scope :for_email, ->(email) { where("LOWER(email) = ?", email.to_s.strip.downcase) }

  def claimed?
    claimed_at.present?
  end

  def claim!
    update!(claimed_at: Time.current) unless claimed?
  end

  private

  def normalize_email
    self.email = email&.strip&.downcase
  end

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def email_not_banned
    errors.add(:email, "is banned from events") if Ban.banned?(email)
  end
end
