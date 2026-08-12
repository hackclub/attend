# Opt-in public participant profiles. No authentication — anyone with the
# link can view, but only profiles the participant explicitly enabled resolve.
class PublicProfilesController < ApplicationController
  skip_before_action :set_current_attributes

  # One card on the profile: the event plus how the participant was involved.
  ProfileEvent = Struct.new(:event, :attended, :staffed)

  def show
    @participant = find_participant
    return render :not_found, status: :not_found if @participant.nil?

    @profile_events = profile_events_for(@participant)
    @attended_count = @profile_events.count(&:attended)
    @staffed_count = @profile_events.count(&:staffed)
    @show_map = @profile_events.any? { |pe| pe.event.venue_coordinates.present? }
  end

  # Map data is fetched by the Stimulus controller as JSON rather than being
  # embedded in the page, so participant-influenced strings never pass through
  # an HTML context.
  def markers
    participant = find_participant
    return head :not_found if participant.nil?

    render json: profile_events_for(participant).filter_map { |pe| map_marker_for(pe.event) }
  end

  private

  def find_participant
    Participant.find_by(
      public_profile_enabled: true,
      public_profile_slug: params[:slug].to_s.strip.downcase
    )
  end

  # Attended and staffed events merged into one newest-first list, deduplicated
  # so an event someone both attended and staffed appears once with both flags.
  def profile_events_for(participant)
    event_preloads = [ :event_series, { logo_attachment: :blob, banner_attachment: :blob } ]
    attended_events = participant.public_profile_participant_events
      .preload(event: event_preloads)
      .map(&:event)
    staffed_events = participant.public_profile_staff_events.preload(event_preloads).to_a
    staffed_ids = staffed_events.map(&:id).to_set

    entries = {}
    attended_events.each do |event|
      entries[event.id] = ProfileEvent.new(event, true, staffed_ids.include?(event.id))
    end
    staffed_events.each do |event|
      entries[event.id] ||= ProfileEvent.new(event, false, true)
    end

    entries.values.sort_by { |pe| pe.event.starts_at || Time.current }.reverse
  end

  def map_marker_for(event)
    coordinates = event.venue_coordinates
    return nil if coordinates.nil?

    {
      lat: coordinates[:lat],
      lon: coordinates[:lon],
      name: event.name,
      location: [ event.location_city, event.location_country ].compact_blank.join(", "),
      logo_url: marker_logo_url(event)
    }
  end

  def marker_logo_url(event)
    logo = event.effective_logo
    return nil unless logo&.attached?

    if logo.variable?
      rails_representation_path(logo.variant(resize_to_fill: [ 80, 80 ]), only_path: true)
    elsif logo.content_type == "image/svg+xml"
      rails_storage_proxy_path(logo, only_path: true)
    end
  end
end
