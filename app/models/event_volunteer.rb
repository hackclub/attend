# Someone working an event without an event role: they see nothing of its
# participants and can't sign in to the admin, but they're on the roster so
# the event can see whether they've done their training. Deliberately a
# separate table rather than another EventRoleAssignment role, because many
# policies grant access on *any* role assignment.
class EventVolunteer < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event
  belongs_to :user
  belongs_to :added_by, class_name: "User", optional: true

  validates :user_id, uniqueness: { scope: :event_id, message: "is already a volunteer at this event" }
end
