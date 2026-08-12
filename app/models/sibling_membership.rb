class SiblingMembership < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :sibling_group
  belongs_to :participant

  validates :participant_id, uniqueness: { scope: :sibling_group_id }
end
