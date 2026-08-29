class IncidentReport < ApplicationRecord
  include NormalizesPhoneNumbers
  has_paper_trail skip: [ :summary, :details ]

  self.implicit_order_column = "created_at"

  encrypts :summary, :details

  belongs_to :event, optional: true
  belongs_to :user, optional: true

  # An event is "recent" (and so eligible for emergency priority + calls) if it
  # is upcoming, running, or ended within the last month. Custom events (not on
  # Attend) are historical, so they never qualify.
  EMERGENCY_EVENT_WINDOW = 1.month

  has_many :comments, class_name: "IncidentReportComment", dependent: :destroy

  has_many_attached :attachments

  MAX_ATTACHMENT_BYTE_SIZE = 25.megabytes
  MAX_ATTACHMENT_COUNT = 10

  ROLES = {
    "event_volunteer" => "Event Volunteer",
    "event_point_of_contact" => "Event Point of Contact",
    "hq_employee" => "Hack Club HQ Employee / Contractor",
    "parent" => "Parent",
    "participant" => "Participant"
  }.freeze

  INCIDENT_TYPES = {
    "event_safety" => "Event Safety / Conduct Issues",
    "medical_emergency" => "Medical Emergency",
    "hq_staff" => "Incident involving Hack Club Staff",
    "other" => "Other"
  }.freeze

  PRIORITIES = {
    "emergency" => "Emergency – Need resolution ASAP",
    "elevated" => "Elevated – Need resolution in 2-3 hours",
    "standard" => "Standard – 24-hour response is OK"
  }.freeze

  enum :status, { open: "open", in_review: "in_review", resolved: "resolved" }

  normalizes_phone_number :reporter_phone

  validates :reporter_name, :reporter_email, :reporter_phone, presence: true
  # A safety report we can't call back on is close to useless.
  validates :reporter_phone, e164_phone: true, allow_blank: true
  validates :reporter_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :reporter_role, presence: true, inclusion: { in: ROLES.keys }
  validates :incident_type, presence: true, inclusion: { in: INCIDENT_TYPES.keys }
  validates :priority, presence: true, inclusion: { in: PRIORITIES.keys }
  validates :summary, :details, presence: true

  validate :acceptable_attachments
  validate :event_or_custom_event_present

  before_validation :force_emergency_priority_if_services_called
  before_validation :downgrade_emergency_for_old_events

  def event_name
    event&.name || custom_event_name
  end

  def emergency_allowed?
    return false if event.blank? # custom / historical events
    return true if event.ends_at.blank?

    event.ends_at >= EMERGENCY_EVENT_WINDOW.ago
  end

  def medical_emergency?
    incident_type == "medical_emergency"
  end

  def emergency?
    priority == "emergency"
  end

  # Records that the given caller acknowledged the emergency call. Idempotent
  # per phone number. Adds a timeline comment on first acknowledgement.
  # Returns the full, ordered list of acknowledger names.
  def record_acknowledgement!(name:, phone:)
    acks = acknowledgements.dup
    unless acks.any? { |a| a["phone"] == phone }
      acks << { "name" => name, "phone" => phone, "at" => Time.current.iso8601 }
      update!(acknowledgements: acks)

      comment = comments.create!(
        source: "phone",
        body: "#{name.presence || phone} acknowledged the incident via emergency phone call."
      )
      SendIncidentReportCommentToSlackJob.perform_later(comment.id) if slack_message_ts.present?
    end
    acknowledger_names
  end

  def acknowledger_names
    acknowledgements.map { |a| a["name"].presence || a["phone"] }
  end

  def role_label
    ROLES[reporter_role]
  end

  def incident_type_label
    INCIDENT_TYPES[incident_type]
  end

  def priority_label
    PRIORITIES[priority]
  end

  private

  def force_emergency_priority_if_services_called
    self.priority = "emergency" if emergency_services_called? && emergency_allowed?
  end

  def downgrade_emergency_for_old_events
    self.priority = "elevated" if priority == "emergency" && !emergency_allowed?
  end

  def event_or_custom_event_present
    return if event_id.present? || custom_event_name.present?

    errors.add(:base, "Please choose an event")
  end

  def acceptable_attachments
    return unless attachments.attached?

    if attachments.count > MAX_ATTACHMENT_COUNT
      errors.add(:attachments, "can include at most #{MAX_ATTACHMENT_COUNT} files")
    end

    attachments.each do |attachment|
      next unless attachment.byte_size > MAX_ATTACHMENT_BYTE_SIZE

      errors.add(:attachments, "#{attachment.filename} is too large (max 25MB per file)")
    end
  end
end
