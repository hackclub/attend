# Fills in the Apple and Google place ids for an event's venue. Runs after a
# venue is added or changed (see Event#queue_place_id_resolution) and from
# the events:resolve_place_ids backfill. Each provider is only consulted when
# its id is missing, so an id picked in the venue form is never overwritten.
class ResolveVenuePlaceIdsJob < ApplicationJob
  queue_as :default

  def perform(event_id)
    event = Event.find_by(id: event_id)
    return unless event&.venue_lookup_possible?

    updates = {}
    if event.apple_place_id.blank?
      place = AppleMapsService.find_place(name: event.venue_name, latitude: event.location_latitude, longitude: event.location_longitude)
      updates[:apple_place_id] = place[:id] if place
    end
    if event.google_place_id.blank?
      place = GooglePlacesService.find_place(name: event.venue_name, latitude: event.location_latitude, longitude: event.location_longitude)
      updates[:google_place_id] = place[:id] if place
    end

    if updates.any?
      # Saved with callbacks so WalletPassUpdatable refreshes passes: the
      # Apple id adds a directions action to the wallet pass.
      event.assign_attributes(updates)
      event.save!(validate: false)
    end
    Rails.logger.info("[ResolveVenuePlaceIdsJob] Event #{event.id}: resolved #{updates.keys.join(', ').presence || 'nothing'}")
  end
end
