module RegistrationChangeRequests
  # Closes a pending request without applying it and without emailing the
  # participant. For requests that change nothing, duplicates, and requests
  # on registrations that are no longer active.
  class Dismiss
    def self.call(request:, reviewer:)
      request.with_lock do
        raise ArgumentError, "Request has already been resolved" unless request.pending?

        request.update!(status: :dismissed, resolved_by: reviewer, resolved_at: Time.current)
      end
      request
    end
  end
end
