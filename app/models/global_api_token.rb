class GlobalApiToken < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true
  validate :owner_is_global_admin

  # A nil expires_at means the token never expires.
  scope :active, -> {
    where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  attr_accessor :token

  # Prefixes distinguish Attend tokens at a glance and help secret scanners
  # (GitHub push protection, etc.) recognize a leaked credential.
  TOKEN_PREFIX = "attn_".freeze

  def self.generate_for(user, name: nil, expires_in: nil)
    token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    global_api_token = create!(
      user: user,
      token_digest: Digest::SHA256.hexdigest(token),
      name: name,
      expires_at: expires_in&.from_now
    )
    global_api_token.token = token
    global_api_token
  end

  def self.find_by_token(token)
    return nil if token.blank?

    digest = Digest::SHA256.hexdigest(token)
    active.find_by(token_digest: digest)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def active?
    !expired? && !revoked?
  end

  private

  def owner_is_global_admin
    return if user&.global_admin?

    errors.add(:user, "must be a global admin to hold a global API token")
  end
end
