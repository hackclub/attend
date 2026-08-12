class SeriesRoleAssignment < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :user
  belongs_to :event_series

  enum :role, {
    owner: "owner",
    organizer: "organizer"
  }

  # Human-readable permission breakdown for each role, surfaced when adding or
  # reviewing series members. Keep in sync with the Pundit policies that
  # enforce access. Both roles act as event admins on every event in the
  # series; owners additionally manage the series itself.
  ROLE_DETAILS = {
    "owner" => {
      label: "Owner",
      summary: "Full control of this series and every event in it.",
      can: [
        "Edit the series name, logo, and banner",
        "Add and remove series members",
        "Create new events in this series",
        "Act as event admin on every event in the series"
      ],
      cannot: []
    },
    "organizer" => {
      label: "Organizer",
      summary: "Runs events within this series.",
      can: [
        "Create new events in this series",
        "Act as event admin on every event in the series"
      ],
      cannot: [
        "Edit the series itself",
        "Add or remove series members"
      ]
    }
  }.freeze

  validates :role, presence: true
  validates :user_id, presence: true, uniqueness: { scope: :event_series_id }
  validates :event_series_id, presence: true
end
