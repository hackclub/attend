# What one MCP connection is allowed to see. A connection is an OAuth client
# application authorized by one user — the same unit the profile page lists and
# disconnects — so these settings survive the token refreshes the client does
# behind the scenes.
#
# Two independent restrictions:
#
#   all_events: false  the connection only reaches the listed events
#   anonymize:  true   names come back as initials and contact details are
#                      stripped from every response
#
# Both only ever tighten in place: the consent screen writes them when the user
# authorizes, the dashboard can narrow them further, and the MCP server itself
# can turn anonymization on. Widening means re-authorizing the client, which
# puts the user back in front of the consent screen.
class McpConnectionSetting < ApplicationRecord
  ENABLED_BY = %w[consent dashboard mcp].freeze

  belongs_to :application, class_name: "Toolchest::OauthApplication"

  has_many :mcp_connection_events, dependent: :delete_all
  has_many :events, through: :mcp_connection_events

  validates :resource_owner_id, presence: true
  validates :anonymize_enabled_by, inclusion: { in: ENABLED_BY }, allow_nil: true
  validate :restricted_connections_name_at_least_one_event

  scope :for_user, ->(user) { where(resource_owner_id: user.id.to_s) }

  def self.for(application_id, user)
    return nil if application_id.blank? || user.nil?

    find_by(application_id: application_id, resource_owner_id: user.id.to_s)
  end

  # nil means "every event this user can reach" — callers treat nil as no
  # restriction rather than as an empty allowlist.
  def permitted_event_ids
    return nil if all_events?

    events.pluck(:id)
  end

  def restricted_to_events? = !all_events?

  def permits_event?(event)
    return true if all_events?

    event.present? && mcp_connection_events.exists?(event_id: event.id)
  end

  # Turning anonymization on is one-way from the MCP server's side; only the
  # human can lift it, and only by re-authorizing the client.
  def anonymize!(source)
    return true if anonymize?

    update!(anonymize: true, anonymize_enabled_at: Time.current, anonymize_enabled_by: source.to_s)
  end

  # Narrows the event allowlist to a subset of what it already permits. Ids that
  # the connection can't already reach are ignored, so this can never widen.
  def narrow_events!(event_ids)
    event_ids = Array(event_ids).map(&:to_s).uniq
    event_ids &= permitted_event_ids.map(&:to_s) if restricted_to_events?
    return false if event_ids.empty?

    transaction do
      mcp_connection_events.where.not(event_id: event_ids).delete_all
      (event_ids - mcp_connection_events.pluck(:event_id)).each do |event_id|
        mcp_connection_events.create!(event_id: event_id)
      end
      update!(all_events: false)
    end
    true
  end

  private

  # An empty allowlist would silently mean "nothing", which reads as a bug to
  # whoever set it. all_events is how you say "everything".
  def restricted_connections_name_at_least_one_event
    return if all_events?
    return if mcp_connection_events.any?

    errors.add(:base, "an event-restricted connection needs at least one event")
  end
end
