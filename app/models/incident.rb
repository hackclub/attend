class Incident < ApplicationRecord
  has_paper_trail skip: [ :summary, :details, :actions_taken ]

  self.implicit_order_column = "created_at"

  encrypts :summary, :details, :actions_taken

  belongs_to :event
  belongs_to :participant_event, optional: true
  belongs_to :reported_by, class_name: "User", foreign_key: "reported_by_user_id"

  has_one :participant, through: :participant_event

  has_many :incident_participants, dependent: :destroy
  has_many :participant_events, through: :incident_participants
  has_many :participants, through: :participant_events, source: :participant

  has_many :incident_helping_staff, dependent: :destroy
  has_many :helping_staff, through: :incident_helping_staff, source: :user

  has_many :comments, class_name: "IncidentComment", dependent: :destroy

  enum :category, { safeguarding: "safeguarding", medical: "medical", behavior: "behavior", other: "other" }
  enum :severity, { low: "low", medium: "medium", high: "high", critical: "critical" }
  enum :status, { open: "open", in_review: "in_review", closed: "closed" }

  # Pre-ticked on the new incident form, and used by the MCP toolbox when no
  # roles are given.
  DEFAULT_VISIBLE_TO_ROLES = %w[event_admin safeguarding_lead].freeze

  # The form posts a hidden "" so that unticking every role still sends the
  # param (and clears it); drop it before it's stored.
  normalizes :visible_to_roles, with: ->(roles) { roles.compact_blank }

  validates :event_id, presence: true
  validates :reported_by_user_id, presence: true
  validates :category, presence: true
  validates :severity, presence: true

  scope :open_incidents, -> { where(status: %w[open in_review]) }
  scope :for_roles, ->(roles) { where("visible_to_roles && ARRAY[?]::varchar[]", roles) }
  # What IncidentPolicy lets event staff see: incidents shared with one of their
  # roles, plus the ones they reported themselves.
  scope :visible_to_staff, ->(user, roles) { for_roles(roles).or(where(reported_by_user_id: user.id)) }
end
