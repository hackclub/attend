class BanEmail < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :ban

  before_validation :normalize_email

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { case_sensitive: false, scope: :ban_id }
  # Admins adding a ban by hand are told if the email is already listed. The
  # UCAT sync deliberately keeps its own copy alongside lapsed or revoked bans
  # (Ban.banned? checks across all of them), so it skips this.
  validate :not_on_another_ban, if: -> { ban.nil? || ban.manual? }

  private

  def not_on_another_ban
    others = BanEmail.where("LOWER(email) = ?", email.to_s.downcase)
    others = others.where.not(ban_id: ban_id) if ban_id
    others = others.where.not(id: id) if persisted?
    errors.add(:email, :taken, message: "is already on a ban list") if others.exists?
  end

  def normalize_email
    self.email = email&.strip&.downcase
  end
end
