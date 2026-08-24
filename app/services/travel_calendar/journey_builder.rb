module TravelCalendar
  class JourneyBuilder
    def initialize(event:)
      @event = event
    end

    def call
      scheduled, unscheduled = participant_events.flat_map { |participant_event|
        participant_event.travels.map { |travel| build_entry(participant_event, travel) }
      }.partition { |entry| entry[:primary_time_at].present? }

      scheduled.sort_by { |entry| [ entry[:primary_time_at], participant_sort_name(entry), entry[:id].to_s ] } +
        unscheduled.sort_by { |entry| [ participant_sort_name(entry), entry[:id].to_s ] }
    end

    private

    attr_reader :event

    def participant_events
      event.participant_events
        .where(status: :complete)
        .includes(:participant, :groups, { scans: :scan_context }, travels: :travel_legs)
    end

    def build_entry(participant_event, travel)
      participant = participant_event.participant
      primary_time_at = travel.calendar_time

      {
        id: travel.id,
        participant_id: participant.id,
        participant_event_id: participant_event.id,
        participant_name: participant.full_name,
        participant_preferred_name: participant.preferred_name,
        direction: travel.direction,
        mode: travel.mode,
        primary_time_at: primary_time_at,
        agenda_date: primary_time_at&.in_time_zone(event.event_time_zone)&.to_date,
        route: travel.calendar_route,
        reference: travel.calendar_reference,
        details: travel.notes,
        pickup_state: pickup_state(participant_event, travel),
        is_unaccompanied_minor: travel.is_unaccompanied_minor? && participant_event.um_approved?,
        groups: groups_for(participant_event)
      }
    end

    def pickup_state(participant_event, travel)
      return nil if travel.outbound?

      contexts = participant_event.scans.filter_map(&:scan_context)
      return :collected if contexts.any?(&:is_travel_pickup?)
      return :checked_in if contexts.any?(&:checks_in?)
      return :pickup_not_needed if travel.pickup_dismissed?

      :awaiting_pickup
    end

    def groups_for(participant_event)
      return [] unless event.groups_enabled?

      participant_event.groups.sort_by(&:name).map do |group|
        { id: group.id, name: group.name, color: group.normalized_color }
      end
    end

    def participant_sort_name(entry)
      entry[:participant_name].to_s.downcase
    end
  end
end
