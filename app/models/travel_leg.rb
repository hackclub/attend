class TravelLeg < ApplicationRecord
  include TravelCalendarCacheInvalidatable

  has_paper_trail ignore: [ :last_tracked_at, :live_status, :live_departure_time, :live_arrival_time, :live_data ]

  self.implicit_order_column = "created_at"

  belongs_to :travel
  belongs_to :picked_up_by, class_name: "User", optional: true, foreign_key: :picked_up_by_user_id

  AIRPORT_CODE_REGEX = /\A[A-Z0-9]{3,4}\z/

  validates :position, presence: true
  validates :flight_code, :departure_airport, :arrival_airport, :departure_time, :arrival_time,
            presence: { message: "is required when adding a flight leg" },
            if: :any_flight_field_changed?
  validates :departure_airport,
            format: { with: AIRPORT_CODE_REGEX, message: "must be a 3-letter IATA or 4-letter ICAO code" },
            if: :departure_airport_changed?,
            allow_blank: true
  validates :arrival_airport,
            format: { with: AIRPORT_CODE_REGEX, message: "must be a 3-letter IATA or 4-letter ICAO code" },
            if: :arrival_airport_changed?,
            allow_blank: true
  # Set by TravelLegDateMerging when the times came from a form as local
  # wall-clock times. Those can't be read without a zone, so one is required
  # rather than guessing UTC.
  attribute :entered_as_local_time, :boolean, default: false

  validates :departure_time_zone,
            presence: { message: "is needed: we don't know the time zone for that airport, so pick one" },
            if: -> { entered_as_local_time && departure_time.present? }
  validates :arrival_time_zone,
            presence: { message: "is needed: we don't know the time zone for that airport, so pick one" },
            if: -> { entered_as_local_time && arrival_time.present? }
  validate :arrival_after_departure, if: -> { departure_time_changed? || arrival_time_changed? }

  normalizes :departure_airport, with: ->(v) { v.to_s.strip.upcase.presence }
  normalizes :arrival_airport,   with: ->(v) { v.to_s.strip.upcase.presence }

  after_update :notify_flight_landed, if: :inbound_just_landed?

  delegate :inbound?, :outbound?, to: :travel

  def display_route
    "#{departure_airport} → #{arrival_airport}"
  end

  # Leg times are stored as true UTC. These return them in the zone they were
  # entered in, so they read the same as the ticket. Legs saved before zones
  # were recorded (and imported ones) fall back to the airport's zone, then UTC.
  def local_departure_time = in_leg_zone(departure_time, departure_time_zone, departure_airport)
  def local_arrival_time = in_leg_zone(arrival_time, arrival_time_zone, arrival_airport)

  # The value to pre-select in a form's zone picker: blank ("Auto") when the
  # stored zone is just the airport's, so changing the airport re-derives it.
  def time_zone_pick(endpoint)
    stored = public_send(:"#{endpoint}_time_zone").presence
    return "" if stored.nil?

    airport_zone = FlightTrackingService.airport_timezone(public_send(:"#{endpoint}_airport"))
    same = airport_zone && ActiveSupport::TimeZone[airport_zone]&.tzinfo == ActiveSupport::TimeZone[stored]&.tzinfo
    same ? "" : stored
  end

  def fetch_oag_instance_key!
    return oag_schedule_instance_key if oag_schedule_instance_key.present?
    return nil if flight_code.blank? || departure_time.blank?

    result = FlightTrackingService.fetch_flight(flight_code, departure_time.to_date, destination_airport: arrival_airport, origin_airport: departure_airport)
    new_id = result && result["scheduleInstanceKey"]
    return nil if new_id.blank?

    update!(oag_schedule_instance_key: new_id)
    new_id
  end

  def fetch_known_flight_data!
    return nil if oag_schedule_instance_key.blank? || departure_time.blank?

    data = FlightTrackingService.fetch_flight_by_id(oag_schedule_instance_key, departure_date: departure_time.to_date)
    return nil if data.blank?

    # A stale key can point at the through-flight instance of a multi-stop
    # flight number (its departure is the origin's, not this leg's). Drop it
    # so fetch_live_data! re-resolves against both endpoints.
    if departure_airport.present? && !OagFlightService.airport_match?(data, "departure", departure_airport)
      update!(oag_schedule_instance_key: nil)
      return nil
    end

    parsed = FlightTrackingService.parse_flight_data(data)

    update!(
      live_status: parsed[:status],
      live_departure_time: parsed[:actual_departure] || parsed[:scheduled_departure],
      live_arrival_time: parsed[:predicted_arrival] || parsed[:scheduled_arrival],
      oag_flight_data: data,
      last_tracked_at: Time.current
    )

    parsed
  end

  def fetch_live_data!
    known = fetch_known_flight_data!
    return known if known.present?

    return nil if flight_code.blank? || departure_time.blank?

    data = FlightTrackingService.fetch_flight(
      flight_code,
      departure_time.to_date,
      destination_airport: arrival_airport,
      origin_airport: departure_airport
    )

    return nil if data.blank?

    parsed = FlightTrackingService.parse_flight_data(data)
    attrs = {
      live_status: parsed[:status],
      live_departure_time: parsed[:actual_departure] || parsed[:scheduled_departure],
      live_arrival_time: parsed[:predicted_arrival] || parsed[:scheduled_arrival],
      live_data: data,
      last_tracked_at: Time.current
    }
    # Persist the resolved scheduleInstanceKey so future refreshes hit the
    # cheap single-flight endpoint instead of re-resolving via search.
    attrs[:oag_schedule_instance_key] = parsed[:schedule_instance_key] if parsed[:schedule_instance_key].present?
    update!(attrs)

    parsed
  end

  def live_tracking_stale?
    return true if last_tracked_at.blank?
    last_tracked_at < 5.minutes.ago
  end

  def live_tracking_data
    return FlightTrackingService.parse_flight_data(oag_flight_data) if oag_flight_data.present?

    return nil if live_data.blank?
    FlightTrackingService.parse_flight_data(live_data)
  end

  def status_color
    FlightTrackingService.status_color(live_status)
  end

  def status_label
    FlightTrackingService.status_label(live_status)
  end

  def travel_picked_up?
    travel_picked_up_at.present?
  end

  def mark_travel_picked_up!(user)
    with_lock do
      return self if travel_picked_up?

      update!(travel_picked_up_at: Time.current, picked_up_by: user)
    end

    self
  end

  def unmark_travel_picked_up!
    update!(travel_picked_up_at: nil, picked_up_by: nil)
  end

  private

  def in_leg_zone(time, stored_zone, airport)
    return nil if time.blank?

    zone = ActiveSupport::TimeZone[stored_zone.to_s] if stored_zone.present?
    zone ||= FlightTrackingService.airport_timezone(airport)
    time.in_time_zone(zone || "UTC")
  end

  def arrival_after_departure
    return if departure_time.blank? || arrival_time.blank?
    return if arrival_time > departure_time

    errors.add(:arrival_time, "must be after the departure time (check the date and time zone)")
  end

  def travel_calendar_event_ids
    travel_ids = [ travel_id, saved_change_to_travel_id&.first ].compact
    Travel.joins(:participant_event).where(id: travel_ids).distinct.pluck("participant_events.event_id")
  end

  def any_flight_field_changed?
    return true if new_record? && any_flight_field_present?

    flight_code_changed? ||
      departure_airport_changed? ||
      arrival_airport_changed? ||
      departure_time_changed? ||
      arrival_time_changed? ||
      confirmation_code_changed?
  end

  def any_flight_field_present?
    flight_code.present? ||
      departure_airport.present? ||
      arrival_airport.present? ||
      departure_time.present? ||
      arrival_time.present? ||
      confirmation_code.present?
  end

  def just_landed?
    saved_change_to_live_status? && live_status.include?("Arrived") && final_leg?
  end

  def inbound_just_landed?
    inbound? && just_landed?
  end

  def final_leg?
    travel.travel_legs.order(:position).last.id == id
  end

  def notify_flight_landed
    participant_event = travel.participant_event
    return unless participant_event

    event = participant_event.event
    participant = participant_event.participant

    ExpoPushService.notify_flight_landed(
      event: event,
      participant_name: participant.display_name,
      flight_code: flight_code,
      participant_event_id: participant_event.id
    )
  end
end
