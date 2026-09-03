class EventRoleAssignment < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :user
  belongs_to :event

  enum :role, {
    event_admin: "event_admin",
    ops: "ops",
    limited: "limited",
    safeguarding_lead: "safeguarding_lead",
    read_only: "read_only"
  }

  # Roles that do the job without seeing a participant's most identifying
  # details: they get age instead of an exact date of birth, no address of any
  # kind — not the home address, not the travel pickup address — and no phone
  # numbers, plus nothing at all for the people around a participant (guardian
  # and emergency contact contact details). The exceptions are the
  # participant's own email address, which these roles search and work from
  # every day, and an emergency contact's first name and phone number, which
  # someone running an incident has to be able to dial. Medical records are
  # deliberately NOT restricted for the same reason. Enforced through
  # User#can_view_participant_pii?, which every surface that renders or exports
  # those fields checks.
  PII_RESTRICTED_ROLES = %w[limited].freeze

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
    "limited" => {
      label: "Limited",
      summary: "Day-to-day logistics, without phone numbers, addresses, or exact birthdays.",
      can: [
        "View and edit travel and accommodation",
        "Manage groups and rooming",
        "View full medical records, so they can help in an incident",
        "View consents and notes",
        "See age at the event, instead of a date of birth",
        "See attendee email addresses, and search by them",
        "See the first name and phone number of an emergency contact"
      ],
      cannot: [
        "See exact dates of birth",
        "See any address, at home or for travel pickup",
        "See phone numbers, other than an emergency contact one",
        "See a guardian email address, or edit guardian details",
        "Work the support inbox",
        "Manage staff",
        "Add or remove participants",
        "Access safeguarding records"
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
