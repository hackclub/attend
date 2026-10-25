# A single API key scoped to one event series.
#
# Where an EventApiToken can only ever act on the one event it was issued for,
# a series token acts on every event inside its series — so a series organizer
# running a dozen events holds one credential instead of a dozen. It is also
# the only credential that may create events through the API, and the series it
# belongs to is the series the new event lands in (callers never choose).
#
# Like the other token kinds it authenticates without a user: requests carrying
# one have no `current_user`, so endpoints that need a person (notes, the full
# participant payload) stay closed to it.
class SeriesApiToken < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :event_series
  belongs_to :user, optional: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # Raw token is exposed once, right after generate/rotate, then never again.
  attr_accessor :token

  # Prefixes distinguish Attend tokens at a glance and help secret scanners
  # (GitHub push protection, Revoker) recognize a leaked credential. Shared
  # with the event and global token kinds on purpose — a scanner only has to
  # know the one prefix.
  TOKEN_PREFIX = "attn_".freeze

  # Builds the stored display name by prefixing the creator's email local part,
  # e.g. creator avery@hackclub.com + "outernet-ops" => "avery@outernet-ops".
  # Mirrors EventApiToken.build_name so both lists read the same way.
  def self.build_name(user, raw_name)
    local = user&.email.to_s.split("@").first.presence
    cleaned = raw_name.to_s.strip
    return cleaned if local.blank?

    "#{local}@#{cleaned}"
  end

  def self.generate_for(event_series, user:, name:)
    token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    series_api_token = create!(
      event_series: event_series,
      user: user,
      name: build_name(user, name),
      token_digest: Digest::SHA256.hexdigest(token)
    )
    series_api_token.token = token
    series_api_token
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
