class GlobalApiToken < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true
  validate :owner_is_global_admin
  validate :scopes_are_known

  # A nil expires_at means the token never expires.
  scope :active, -> {
    where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  attr_accessor :token

  # Prefixes distinguish Attend tokens at a glance and help secret scanners
  # (GitHub push protection, etc.) recognize a leaked credential.
  TOKEN_PREFIX = "attn_".freeze

  # Narrow capabilities a token can be limited to, mapped to the label shown
  # when issuing one. An API controller opts into a scope with
  # `required_scope`; anything that hasn't is unreachable by a scoped token.
  SCOPES = {
    "bans:write" => "Add emails to the ban list"
  }.freeze

  def self.generate_for(user, name: nil, expires_in: nil, scopes: [])
    token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    global_api_token = create!(
      user: user,
      token_digest: Digest::SHA256.hexdigest(token),
      name: name,
      expires_at: expires_in&.from_now,
      scopes: Array.wrap(scopes).map(&:to_s).reject(&:blank?).uniq
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

  # No scopes means the token was issued before scoping existed, or was
  # deliberately issued unrestricted — either way it carries the owner's full
  # global-admin access.
  def unrestricted?
    scopes.empty?
  end

  # Scoped tokens are deny-by-default: a controller is reachable only if it
  # names a scope this token holds.
  def permits?(scope)
    return true if unrestricted?

    scope.present? && scopes.include?(scope)
  end

  def scope_labels
    scopes.map { |scope| SCOPES.fetch(scope, scope) }
  end

  private

  def owner_is_global_admin
    return if user&.global_admin?

    errors.add(:user, "must be a global admin to hold a global API token")
  end

  def scopes_are_known
    unknown = scopes - SCOPES.keys
    return if unknown.empty?

    errors.add(:scopes, "include unknown values: #{unknown.join(', ')}")
  end
end
