module TravelPickupMarkable
  extend ActiveSupport::Concern

  private

  def mark_travel_pickup(participant_event, user)
    travel = participant_event.travel_inbound
    return if travel.blank?
    return unless travel.plane?

    final_leg = travel.travel_legs.order(:position).last
    return if final_leg.blank?

    final_leg.mark_travel_picked_up!(user)
  end
end
