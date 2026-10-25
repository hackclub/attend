# One short link on badge.hackclub.com, printed as a QR code on the physical
# badge someone wears at an event: scan badge.hackclub.com/t/<slack id> and you
# land wherever the badge's owner points it — their site, their GitHub, their
# project. Owners set it on their Attend profile.
#
# Keyed by Slack ID, not by user. That's what the printed QR codes encode, and
# it's all that badgekit — the standalone app this replaced — recorded for some
# of its rows, so a redirect can outlive (or predate) an Attend account. `user`
# is the link back, filled in the first time someone saves theirs from the
# profile page.
class BadgeRedirect < ApplicationRecord
  self.implicit_order_column = "created_at"

  # Only ever an http(s) link. Anything else — javascript:, data: — would turn
  # a badge into an XSS vector for whoever scans it.
  ALLOWED_SCHEMES = %w[http https].freeze
  MAX_URL_LENGTH = 2000

  belongs_to :user, optional: true

  normalizes :slack_id, with: ->(value) { value.to_s.strip.upcase.presence }
  normalizes :url, with: ->(value) { normalize_url(value) }

  validates :slack_id, presence: true, uniqueness: true
  validates :url, length: { maximum: MAX_URL_LENGTH }
  validate :url_is_a_web_link

  # The host the QR codes point at. badge.hackclub.com does nothing else: every
  # other path on it bounces back to Attend (see config/routes.rb).
  def self.badge_host = ENV.fetch("BADGE_HOST", "badge.hackclub.com")

  def self.badge_host?(host) = host.to_s.casecmp?(badge_host)

  # Typing "example.com" into the settings field means the obvious thing rather
  # than failing validation, so assume https when no scheme is given at all.
  def self.normalize_url(value)
    raw = value.to_s.strip
    return nil if raw.blank?

    raw.match?(%r{\A[a-z][a-z0-9+.\-]*://}i) ? raw : "https://#{raw}"
  end

  def self.for_slack_id(slack_id) = find_by(slack_id: slack_id)

  def public_url = "https://#{self.class.badge_host}/t/#{slack_id}"

  private

  def url_is_a_web_link
    return if url.blank?

    uri = URI.parse(url)
    return if ALLOWED_SCHEMES.include?(uri.scheme) && uri.host.present? && !self.class.badge_host?(uri.host)

    errors.add(:url, "must be a link starting with https://")
  rescue URI::InvalidURIError
    errors.add(:url, "must be a link starting with https://")
  end
end
