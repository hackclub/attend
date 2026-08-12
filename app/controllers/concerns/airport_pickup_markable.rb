module AirportPickupMarkable
  extend ActiveSupport::Concern

  private

  def mark_airport_pickup(participant_event, user)
    return unless participant_event.travel_inbound.present?

    final_leg = participant_event.travel_inbound.travel_legs.order(:position).last
    return unless final_leg.present?
    return if final_leg.picked_up?

    final_leg.mark_picked_up!(user)
  end
end
