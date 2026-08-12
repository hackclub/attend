class Travel < ApplicationRecord
  has_paper_trail

  self.implicit_order_column = "created_at"

  belongs_to :participant_event
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event
  has_many :travel_legs, -> { order(position: :asc) }, dependent: :destroy

  accepts_nested_attributes_for :travel_legs, allow_destroy: true, reject_if: ->(attrs) {
    attrs[:id].blank? &&
      attrs[:flight_code].blank? &&
      attrs[:departure_airport].blank? &&
      attrs[:arrival_airport].blank?
  }

  enum :direction, { inbound: "inbound", outbound: "outbound" }
  enum :mode, { plane: "plane", train: "train", car: "car", bus: "bus", other: "other" }
  enum :visa_status, { not_required: "not_required", pending: "not_applied", applied: "applied", approved: "approved", denied: "denied" }

  validates :participant_event_id, presence: true
  validates :direction, presence: true


  def flight?
    plane?
  end

  def arrival_display
    if plane? && travel_legs.any?
      last_leg = travel_legs.last
      [ last_leg.arrival_time&.strftime("%b %d, %Y %H:%M"), last_leg.arrival_airport ].compact.join(" - ")
    else
      [ arrival_time&.strftime("%b %d, %Y %H:%M"), arrival_city ].compact.join(" - ")
    end
  end

  def first_departure_time
    if plane? && travel_legs.any?
      travel_legs.first.departure_time
    else
      departure_time
    end
  end

  def last_arrival_time
    if plane? && travel_legs.any?
      travel_legs.last.arrival_time
    else
      arrival_time
    end
  end

  def pickup_dismissed?
    pickup_dismissed_at.present?
  end

  def dismiss_pickup!
    update!(pickup_dismissed_at: Time.current)
  end

  def undismiss_pickup!
    update!(pickup_dismissed_at: nil)
  end
end
