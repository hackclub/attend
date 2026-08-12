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
  validates :body, presence: true
  validate :event_or_ticket_present

  scope :for_roles, ->(roles) { where("visible_to_roles && ARRAY[?]::varchar[]", roles) }
  scope :restricted, -> { where(sensitivity: :restricted) }
  scope :general, -> { where(sensitivity: :normal) }

  private

  def event_or_ticket_present
    return if event_id.present? || ticket_id.present?

    errors.add(:base, "must belong to either an event or a ticket")
  end
end
