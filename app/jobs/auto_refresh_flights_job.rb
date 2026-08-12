class AutoRefreshFlightsJob < ApplicationJob
  queue_as :default

  # Tight polling windows — we only care about catching two transitions:
  # outbound legs taking off, and inbound legs landing.
  OUTBOUND_LEAD = 30.minutes
  INBOUND_LEAD  = 1.hour

  # Terminal statuses for each direction (no need to keep polling).
  OUTBOUND_DONE = %w[Departed EnRoute Arrived Cancelled Diverted].freeze
  INBOUND_DONE  = %w[Arrived Cancelled Diverted].freeze

  def perform
    active_events.find_each do |event|
      next unless event.travel_enabled?

      refresh_active_flights(event)
    end
  end

  def active_events
    Event.where("starts_at <= ? AND ends_at >= ?", 2.days.from_now, 2.days.ago)
  end

  private

  def refresh_active_flights(event)
    leg_ids = collect_active_leg_ids(event)
    return if leg_ids.empty?

    Rails.logger.info("[AutoRefreshFlightsJob] Refreshing #{leg_ids.size} active flights for event #{event.id}")

    leg_ids.each do |leg_id|
      leg = TravelLeg.find_by(id: leg_id)
      next unless leg
      next unless leg.live_tracking_stale?

      begin
        leg.fetch_live_data!
      rescue => e
        Rails.logger.error("[AutoRefreshFlightsJob] Failed to refresh leg #{leg_id}: #{e.message}")
      end
    end

    Rails.cache.delete("airport_mode/#{event.id}/journeys/v2")
  end

  def collect_active_leg_ids(event)
    leg_ids = []

    event.participant_events
      .where(status: :complete)
      .includes(travel_inbound: :travel_legs, travel_outbound: :travel_legs)
      .find_each do |pe|
        [ pe.travel_inbound, pe.travel_outbound ].compact.each do |travel|
          next unless travel.plane?

          travel.travel_legs.each do |leg|
            leg_ids << leg.id if needs_polling?(leg)
          end
        end
      end

    leg_ids
  end

  def needs_polling?(leg)
    return false if leg.flight_code.blank?

    if leg.outbound?
      return false if OUTBOUND_DONE.include?(leg.live_status)
      return false if leg.departure_time.blank?
      Time.current >= leg.departure_time - OUTBOUND_LEAD
    else
      return false if INBOUND_DONE.include?(leg.live_status)
      return false if leg.arrival_time.blank?
      Time.current >= leg.arrival_time - INBOUND_LEAD
    end
  end
end
