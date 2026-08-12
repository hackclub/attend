class BanEmail < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :ban

  before_validation :normalize_email

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { case_sensitive: false, message: "is already on a ban list" }

  private

  def normalize_email
    self.email = email&.strip&.downcase
  end
end
