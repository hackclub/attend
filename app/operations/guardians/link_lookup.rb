module Guardians
  # Guardian operations act on one registration's guardian link. A surface may
  # hand over the record or just the id from its params; an id is looked up
  # inside the registration, and only once the caller has been authorized, so
  # an unknown id answers the way it always has (ActiveRecord::RecordNotFound,
  # after the permission checks).
  module LinkLookup
    private

    def link
      @link ||=
        if @link_reference.is_a?(GuardianParticipantEvent)
          @link_reference
        else
          @participant_event.guardian_participant_events.find(@link_reference)
        end
    end

    def guardian = link.guardian
  end
end
