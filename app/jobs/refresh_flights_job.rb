class RefreshFlightsJob < ApplicationJob
  queue_as :default

  def perform(event_id)
    event = Event.find(event_id)
    cache_key = "airport_mode/#{event_id}/refresh_status"

    leg_ids = collect_leg_ids(event)
    total = leg_ids.size

    update_status(cache_key, event_id, {
      status: "in_progress",
      total: total,
      completed: 0,
      message: "Starting refresh..."
    })

    leg_ids.each_with_index do |leg_id, index|
      leg = TravelLeg.find_by(id: leg_id)
      next unless leg

      begin
        leg.fetch_oag_instance_key! if leg.departure_time.present? && leg.departure_time <= 2.days.from_now
      rescue => e
        Rails.logger.error("[RefreshFlightsJob] Failed to fetch OAG instance key for leg #{leg_id}: #{e.message}")
      end

      begin
        leg.fetch_live_data!
      rescue => e
        Rails.logger.error("[RefreshFlightsJob] Failed to refresh leg #{leg_id}: #{e.message}")
      end

      sleep 0.5 unless index == total - 1

      if (index + 1) % 5 == 0 || index == total - 1
        update_status(cache_key, event_id, {
          status: "in_progress",
          total: total,
          completed: index + 1,
          message: "Refreshed #{index + 1} of #{total} flights..."
        })
      end
    end

    Rails.cache.delete("airport_mode/#{event_id}/journeys/v3")

    update_status(cache_key, event_id, {
      status: "complete",
      total: total,
      completed: total,
      message: "Refreshed #{total} flight leg(s)."
    })
  end

  private

  def collect_leg_ids(event)
    leg_ids = []

    event.participant_events.includes(travel_inbound: :travel_legs, travel_outbound: :travel_legs).find_each do |pe|
      [ pe.travel_inbound, pe.travel_outbound ].compact.each do |travel|
        next unless travel.plane?

        travel.travel_legs.each do |leg|
          next if leg.flight_code.blank?
          leg_ids << leg.id
        end
      end
    end

    leg_ids
  end

  def update_status(cache_key, event_id, data)
    Rails.cache.write(cache_key, data, expires_in: 10.minutes)
    ActionCable.server.broadcast("event_#{event_id}", data)
  end
end
