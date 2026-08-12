class MobileToken < ApplicationRecord
  self.implicit_order_column = "created_at"

  # Shorter expiry for apps handling minor PII data
  DEFAULT_EXPIRY = 14.days
  REFRESH_THRESHOLD = 3.days

  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  attr_accessor :token

  def self.generate_for(user, device_name: nil, expires_in: DEFAULT_EXPIRY)
    token = SecureRandom.urlsafe_base64(32)
    mobile_token = create!(
      user: user,
      token_digest: Digest::SHA256.hexdigest(token),
      device_name: device_name,
      expires_at: expires_in.from_now
    )
    mobile_token.token = token
    mobile_token
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
    expires_at < Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def active?
    !expired? && !revoked?
  end

  def needs_refresh?
    active? && expires_at < REFRESH_THRESHOLD.from_now
  end

  def refresh!
    return nil unless active?

    new_token = self.class.generate_for(user, device_name: device_name)
    revoke!
    new_token
  end
end
