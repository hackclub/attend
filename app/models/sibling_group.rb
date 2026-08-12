class SiblingGroup < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  has_many :sibling_memberships, dependent: :destroy
  has_many :participants, through: :sibling_memberships

  validates :participants, length: { minimum: 2 }, on: :update

  def participant_names
    participants.map(&:display_name).join(", ")
  end
end
