class RoomAssignment < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :room
  belongs_to :participant_event
  belongs_to :rooming_context

  has_one :participant, through: :participant_event
  has_one :event, through: :room
  has_one :accommodation, through: :participant_event

  validates :participant_event_id, uniqueness: { scope: :rooming_context_id, message: "is already assigned to a room for this stay" }
  validate :room_not_full, on: :create

  # Copied from the room so "one room per person per stay" can be a unique
  # index rather than a check that races.
  before_validation { self.rooming_context_id = room&.rooming_context_id }

  scope :main_stay, -> { where(rooming_context_id: RoomingContext.main.select(:id)) }
  scope :staff_overrides, -> { where(staff_override: true) }
  scope :needing_acknowledgment, -> {
    joins(:room)
      .where("flags->>'trans_nb_pairing' = 'true' AND trans_nb_acknowledged = false")
      .where("(SELECT COUNT(*) FROM room_assignments ra2 WHERE ra2.room_id = room_assignments.room_id) >= 2")
  }

  def trans_nb_flagged?
    flags["trans_nb_pairing"] == true || participant_event&.accommodation&.trans_or_nb?
  end

  def age_gap_violation?
    (flags["age_gap"] || 0) > 2
  end

  def display_flags
    result = []
    result << "Age gap: #{flags['age_gap']}y" if flags["age_gap"]&.> 2
    result << "Trans/NB pairing" if flags["trans_nb_pairing"]
    result << "18 with non-18 sibling" if flags["18_with_non18_sibling"]
    result
  end

  private

  def room_not_full
    return unless room

    # Count in SQL so a stale loaded association can't let a room overfill
    occupied = room.room_assignments.where.not(id: id).count + room.staff_count
    if occupied >= room.capacity
      errors.add(:room, "is already at capacity")
    end
  end
end
