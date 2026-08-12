class Room < ApplicationRecord
  self.implicit_order_column = "created_at"

  scope :ordered, -> { order(Arel.sql("position IS NULL, position ASC, created_at ASC")) }

  has_paper_trail

  belongs_to :event
  has_many :room_assignments, dependent: :destroy
  has_many :participant_events, through: :room_assignments

  validates :capacity, presence: true, numericality: { greater_than: 0 }
  validates :name, uniqueness: { scope: :event_id, allow_nil: true }

  scope :with_availability, -> { includes(:room_assignments).where("(SELECT COUNT(*) FROM room_assignments WHERE room_assignments.room_id = rooms.id) < rooms.capacity") }
  scope :staff_rooms, -> { where(staff_only: true) }
  scope :participant_rooms, -> { where(staff_only: false) }

  def full?
    remaining_capacity <= 0
  end

  def occupants
    participant_events.includes(:participant)
  end

  def display_name
    name.presence || "Room #{id.first(8)}"
  end

  def gender_summary
    genders = room_assignments.filter_map do |ra|
      ra.participant_event&.accommodation&.gender_identity
    end
    genders.uniq.join(", ")
  end

  def age_range
    ages = occupant_ages
    return nil if ages.empty?

    min_age, max_age = ages.minmax
    min_age == max_age ? "#{min_age}" : "#{min_age}-#{max_age}"
  end

  def age_gap
    ages = occupant_ages
    return 0 if ages.size < 2

    ages.max - ages.min
  end

  def has_trans_nb_pairing?
    return false if room_assignments.size < 2

    room_assignments.any?(&:trans_nb_flagged?)
  end

  def staff_names_list
    return [] if staff_names.blank?

    staff_names.split(/[,;]/).map(&:strip).reject(&:blank?)
  end

  def staff_count
    staff_names_list.size
  end

  def has_staff?
    staff_names.present?
  end

  def has_participants?
    room_assignments.any?
  end

  def total_occupancy
    room_assignments.size + staff_count
  end

  def remaining_capacity
    capacity - total_occupancy
  end

  def can_add_staff?
    !has_participants? && remaining_capacity > 0
  end

  def can_add_participants?
    !has_staff? && remaining_capacity > 0
  end

  private

  def occupant_ages
    event_date = event.starts_at&.to_date || Date.current
    room_assignments.filter_map { |ra| ra.participant_event&.participant&.age_on(event_date) }
  end
end
