class GroupMembership < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :group
  belongs_to :participant_event

  validates :group_id, uniqueness: { scope: :participant_event_id }
  validate :same_event

  private

  def same_event
    return unless group && participant_event
    return if group.event_id == participant_event.event_id

    errors.add(:base, "group and participant must belong to the same event")
  end
end
