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

  validates :event_id, presence: true
  validates :reported_by_user_id, presence: true
  validates :category, presence: true
  validates :severity, presence: true

  scope :open_incidents, -> { where(status: %w[open in_review]) }
  scope :for_roles, ->(roles) { where("visible_to_roles && ARRAY[?]::varchar[]", roles) }
end
