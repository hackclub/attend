class NfcToken < ApplicationRecord
  class TokenMismatch < StandardError; end
  class InvalidState < StandardError; end

  self.implicit_order_column = "created_at"

  belongs_to :user
  belongs_to :paired_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  before_validation :set_token, on: :create

  validates :token, presence: true, uniqueness: true

  scope :active, -> { where.not(paired_at: nil).where(revoked_at: nil) }
  scope :pending, -> { where(paired_at: nil, revoked_at: nil) }

  def self.ensure_pending_for!(user)
    user.nfc_tokens.pending.order(created_at: :desc).first || user.nfc_tokens.create!
  end

  def pending?
    paired_at.nil? && revoked_at.nil?
  end

  def active?
    paired_at.present? && revoked_at.nil?
  end

  def confirm!(presented_token:, actor:)
    raise InvalidState unless pending?
    raise TokenMismatch unless token == presented_token

    update!(paired_at: Time.current, paired_by: actor)
  end

  def revoke!(actor:)
    update!(revoked_at: Time.current, revoked_by: actor)
  end

  private

  def set_token
    self.token ||= SecureRandom.uuid
  end
end
