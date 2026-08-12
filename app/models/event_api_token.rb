class EventApiToken < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :event
  # The user who created the token. Nullable so a token outlives its creator's
  # account, but retained for the "leo@..." display name and audit context.
  belongs_to :user, optional: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # Raw token is exposed once, right after generate/rotate, then never again.
  attr_accessor :token

  # Builds the stored display name by prefixing the creator's email local part,
  # e.g. creator leo@hackclub.com + "attend-integration-name" => "leo@attend-integration-name".
  def self.build_name(user, raw_name)
    local = user&.email.to_s.split("@").first.presence
    cleaned = raw_name.to_s.strip
    return cleaned if local.blank?

    "#{local}@#{cleaned}"
  end

  # Prefixes distinguish Attend tokens at a glance and help secret scanners
  # (GitHub push protection, etc.) recognize a leaked credential.
  TOKEN_PREFIX = "attn_".freeze

  def self.generate_for(event, user:, name:)
    token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    event_api_token = create!(
      event: event,
      user: user,
      name: build_name(user, name),
      token_digest: Digest::SHA256.hexdigest(token)
    )
    event_api_token.token = token
    event_api_token
  end

  def self.find_by_token(token)
    return nil if token.blank?

    digest = Digest::SHA256.hexdigest(token)
    active.find_by(token_digest: digest)
  end

  # Issues a fresh secret for this token, keeping its name and history.
  def rotate!
    token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    update!(token_digest: Digest::SHA256.hexdigest(token), last_used_at: nil)
    self.token = token
    token
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  def revoked?
    revoked_at.present?
  end

  def active?
    !revoked?
  end
end
