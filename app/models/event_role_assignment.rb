class EventRoleAssignment < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :user
  belongs_to :event

  enum :role, {
    event_admin: "event_admin",
    ops: "ops",
    safeguarding_lead: "safeguarding_lead",
    read_only: "read_only"
  }

  # Human-readable permission breakdown for each role, surfaced when adding or
  # reviewing staff. Keep in sync with the Pundit policies that enforce access.
  ROLE_DETAILS = {
    "event_admin" => {
      label: "Event Admin",
      summary: "Full control of this event.",
      can: [
        "Manage staff and their roles",
        "Add, remove, and withdraw participants",
        "View and edit travel and accommodation",
        "View and edit full medical and safeguarding records",
        "Manage groups and rooming",
        "Regenerate the event API key"
      ],
      cannot: []
    },
    "ops" => {
      label: "Ops",
      summary: "Day-to-day logistics and operations.",
      can: [
        "View and edit travel and accommodation",
        "Manage groups and rooming",
        "View limited medical info (allergies, dietary needs)",
        "View consents and notes"
      ],
      cannot: [
        "Manage staff",
        "Add or remove participants",
        "Access full medical or safeguarding records"
      ]
    },
    "safeguarding_lead" => {
      label: "Safeguarding Lead",
      summary: "Welfare, medical, and safeguarding.",
      can: [
        "View and edit full medical records",
        "View and edit safeguarding information",
        "View consents and notes"
      ],
      cannot: [
        "Manage staff",
        "Add or remove participants",
        "Edit travel or accommodation"
      ]
    },
    "read_only" => {
      label: "Read Only",
      summary: "View-only access — cannot make changes.",
      can: [
        "View participant details and event data",
        "View consents"
      ],
      cannot: [
        "Make any changes",
        "Access safeguarding records"
      ]
    }
  }.freeze

  validates :user_id, presence: true
  validates :event_id, presence: true
  validates :role, presence: true, uniqueness: { scope: %i[user_id event_id] }

  # Series owners and organizers act as event admins on every event in their
  # series, so their access to this event is inherited from the series rather
  # than granted by this row. Inherited members are managed from the series
  # members page and can't be removed at the event level.
  def inherited_from_series?
    series_role.present?
  end

  def series_role
    return nil if event.event_series_id.blank?

    SeriesRoleAssignment.find_by(user_id: user_id, event_series_id: event.event_series_id)&.role
  end
end
