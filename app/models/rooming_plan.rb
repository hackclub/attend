class RoomingPlan < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event
  belongs_to :rooming_context
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :finalized_by_user, class_name: "User", optional: true

  enum :status, {
    draft: "draft",
    preferences_linked: "preferences_linked",
    auto_assigned: "auto_assigned",
    finalized: "finalized"
  }

  validates :room_capacity, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 10 }
  validates :rooming_context_id, uniqueness: true

  before_validation { self.event ||= rooming_context&.event }

  def finalize!(user)
    update!(
      status: :finalized,
      finalized_by_user: user,
      finalized_at: Time.current
    )
  end

  def finalized?
    status == "finalized"
  end

  def can_edit?
    !finalized? && !locked?
  end

  def lock!
    update!(locked: true)
  end

  def unlock!
    update!(locked: false)
  end
end
