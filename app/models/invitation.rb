class Invitation < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validate :no_pending_invitation_exists, on: :create
  validate :email_not_banned, on: :create

  before_validation :normalize_email, on: :create
  before_validation :generate_token, on: :create
  before_validation :set_expiration, on: :create

  scope :pending, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }
  scope :for_email, ->(email) { where("LOWER(email) = ?", email.downcase) }

  def expired?
    expires_at < Time.current
  end

  def accepted?
    accepted_at.present?
  end

  def pending?
    !accepted? && !expired?
  end

  def accept!
    update!(accepted_at: Time.current)
  end

  private

  def normalize_email
    self.email = email&.strip&.downcase
  end

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiration
    self.expires_at ||= 30.days.from_now
  end

  def no_pending_invitation_exists
    return if email.blank? || event_id.blank?

    existing = Invitation.pending.where(event_id: event_id).for_email(email).exists?
    errors.add(:email, "already has a pending invitation for this event") if existing
  end

  def email_not_banned
    errors.add(:email, "is banned from events") if Ban.banned?(email)
  end
end
