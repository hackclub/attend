class Note < ApplicationRecord
  has_paper_trail

  self.implicit_order_column = "created_at"

  encrypts :body

  belongs_to :event, optional: true
  belongs_to :participant_event, optional: true
  belongs_to :ticket, optional: true
  belongs_to :author, class_name: "User", foreign_key: "author_user_id"

  has_one :participant, through: :participant_event

  enum :note_type, { ops: "ops", safeguarding: "safeguarding", logistical: "logistical" }
  enum :sensitivity, { normal: "normal", restricted: "restricted" }

  validates :author_user_id, presence: true
  normalizes :visible_to_roles, with: ->(roles) { Array(roles).map(&:to_s).compact_blank.uniq }

  validates :body, presence: true
  validate :visible_to_roles_are_known
  validate :event_or_ticket_present

  # A note with no visible_to_roles (the admin forms never set any) is visible
  # to every event role.
  scope :for_roles, ->(roles) { where("COALESCE(cardinality(visible_to_roles), 0) = 0 OR visible_to_roles && ARRAY[?]::varchar[]", roles) }
  scope :restricted, -> { where(sensitivity: :restricted) }
  scope :general, -> { where(sensitivity: :normal) }
  # Hides restricted notes from anyone who isn't allowed to read them.
  scope :sensitivity_visible_to, ->(user, event) { restricted_visible_to?(user, event) ? all : general }

  # Restricted notes are readable only by global admins, event admins (incl.
  # series members) and safeguarding leads — regardless of visible_to_roles.
  def self.restricted_visible_to?(user, event)
    return false unless user
    return true if user.global_admin?
    return false unless event

    user.event_admin_for?(event) || user.safeguarding_lead_for?(event)
  end

  private

  def visible_to_roles_are_known
    unknown = Array(visible_to_roles) - EventRoleAssignment.roles.values
    errors.add(:visible_to_roles, "contains unknown roles: #{unknown.join(', ')}") if unknown.any?
  end

  def event_or_ticket_present
    return if event_id.present? || ticket_id.present?

    errors.add(:base, "must belong to either an event or a ticket")
  end
end
