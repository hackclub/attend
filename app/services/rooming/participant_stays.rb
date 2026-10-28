module Rooming
  # The stays one registration is part of, with their room in each. A stay
  # counts when they have a room in it, are on its list, or (for a stay that
  # takes everyone) filled in the accommodation form and aren't exempt.
  class ParticipantStays
    Entry = Data.define(:stay, :room, :finalized) do
      def finalized? = finalized
    end

    def self.for(participant_event)
      new(participant_event).entries
    end

    def initialize(participant_event)
      @participant_event = participant_event
    end

    def entries
      assignments = @participant_event.room_assignments.includes(:room).index_by(&:rooming_context_id)
      listed = @participant_event.rooming_roster_entries.pluck(:rooming_context_id).to_set
      accommodation = @participant_event.accommodation

      @participant_event.event.rooming_contexts.ordered.includes(:rooming_plan).filter_map do |stay|
        in_stay = assignments.key?(stay.id) ||
          (stay.everyone? ? (accommodation.present? && !accommodation.rooming_exempt?) : listed.include?(stay.id))
        next unless in_stay

        Entry.new(stay: stay, room: assignments[stay.id]&.room, finalized: stay.rooming_plan&.finalized? || false)
      end
    end
  end
end
