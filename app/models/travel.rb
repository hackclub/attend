class Travel < ApplicationRecord
  include TravelCalendarCacheInvalidatable

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
  enum :arrangement_status, {
    unknown: "unknown",
    not_arranged: "not_arranged",
    provisional: "provisional",
    confirmed: "confirmed"
  }
  enum :visa_status, { not_required: "not_required", pending: "not_applied", applied: "applied", approved: "approved", denied: "denied" }

  validates :participant_event_id, presence: true
  validates :direction, presence: true
  validates :mode, presence: true, if: -> { provisional? || confirmed? }
  validate :confirmed_details_are_complete, if: :confirmed?

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

  def calendar_time
    if plane?
      inbound? ? travel_legs.last&.arrival_time : travel_legs.first&.departure_time
    elsif car? && inbound?
      expected_arrival_time
    else
      inbound? ? arrival_time : departure_time
    end
  end

  def calendar_route
    case mode
    when "plane"
      airports = travel_legs.flat_map { |leg| [ leg.departure_airport, leg.arrival_airport ] }.compact
      airports.each_with_object([]) { |airport, route| route << airport unless route.last == airport }.join(" → ").presence
    when "train"
      [ train_departure_station, train_arrival_station ].compact_blank.join(" → ").presence
    when "bus"
      [ bus_departure_location, bus_arrival_location ].compact_blank.join(" → ").presence
    when "car"
      origin_address.presence
    when "other"
      other_details.presence
    end
  end

  def calendar_reference
    return travel_legs.filter_map(&:flight_code).join(" · ").presence if plane?

    carrier.presence
  end

  def pickup_dismissed?
    pickup_dismissed_at.present?
  end

  def dismiss_pickup!
    unless inbound?
      errors.add(:base, "Pickup dismissal only applies to inbound travel")
      raise ActiveRecord::RecordInvalid, self
    end

    update!(pickup_dismissed_at: Time.current)
  end

  def undismiss_pickup!
    update!(pickup_dismissed_at: nil)
  end

  private

  def confirmed_details_are_complete
    case mode
    when "plane"
      active_legs = travel_legs.reject(&:marked_for_destruction?)
      errors.add(:travel_legs, "must include at least one complete flight") if active_legs.empty?
    when "train"
      errors.add(:train_departure_station, :blank) if train_departure_station.blank?
      errors.add(:train_arrival_station, :blank) if train_arrival_station.blank?
      errors.add(inbound? ? :arrival_time : :departure_time, :blank) if (inbound? ? arrival_time : departure_time).blank?
    when "bus"
      errors.add(:bus_departure_location, :blank) if bus_departure_location.blank?
      errors.add(:bus_arrival_location, :blank) if bus_arrival_location.blank?
      errors.add(:departure_time, :blank) if departure_time.blank?
      errors.add(:arrival_time, :blank) if arrival_time.blank?
    when "car"
      errors.add(:origin_address, :blank) if origin_address.blank?
      field = inbound? ? :expected_arrival_time : :departure_time
      errors.add(field, :blank) if public_send(field).blank?
    when "other"
      errors.add(:other_details, :blank) if other_details.blank?
    end
  end

  def travel_calendar_event_ids
    participant_event_ids = [ participant_event_id, saved_change_to_participant_event_id&.first ].compact
    ParticipantEvent.where(id: participant_event_ids).distinct.pluck(:event_id)
  end
end
