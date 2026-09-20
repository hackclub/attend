class RegistrationChangeRequest < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail skip: [ :requested_changes, :requester_note, :staff_response ]

  belongs_to :participant_event
  belongs_to :requested_by, class_name: "User"
  belongs_to :resolved_by, class_name: "User", optional: true

  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event

  encrypts :requested_changes, :requester_note, :staff_response

  enum :kind, {
    signed_identity: "signed_identity",
    guardian: "guardian",
    support: "support"
  }

  enum :status, {
    pending: "pending",
    approved: "approved",
    follow_up_needed: "follow_up_needed"
  }

  enum :staff_audience, {
    event_admin: "event_admin",
    operations: "operations",
    safeguarding: "safeguarding"
  }, prefix: :audience

  validates :kind, :status, :staff_audience, presence: true
  validates :requested_changes, presence: true, unless: :support?
  validates :requester_note, presence: true, if: :support?
  validates :kind,
    uniqueness: {
      scope: :participant_event_id,
      conditions: -> { where(status: :pending) },
      message: "already has a pending request"
    },
    if: :pending?
  validate :consequential_requests_use_event_admin_audience
  validate :guardian_replacement_is_eligible

  scope :pending_first, -> {
    order(Arel.sql("CASE registration_change_requests.status WHEN 'pending' THEN 0 ELSE 1 END"), created_at: :desc)
  }

  private

  def consequential_requests_use_event_admin_audience
    return unless signed_identity? || guardian?
    return if audience_event_admin?

    errors.add(:staff_audience, "must be event admin for this request")
  end

  def guardian_replacement_is_eligible
    return unless guardian?
    return unless pending?
    return if participant_event&.guardian_replacement_eligible?

    errors.add(:kind, "requires a minor registration with an existing guardian")
  end
end
