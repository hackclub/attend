module Registration
  # One change to a registration's status. Written by
  # ParticipantEvent#transition_to!, and by the model itself for any status
  # change that didn't come through it, so the history has no gaps.
  class Transition < ApplicationRecord
    self.implicit_order_column = "created_at"

    belongs_to :participant_event
    belongs_to :actor, class_name: "User", optional: true

    enum :cause, {
      # The registration was created (an import, an invitation, signing up).
      created: "created",
      # The participant opened the wizard for the first time.
      started: "started",
      # The participant submitted, by accepting the code of conduct.
      submitted: "submitted",
      document_signed: "document_signed",
      guardian_completed: "guardian_completed",
      # A backlog task found the registration already had everything.
      requirements_met: "requirements_met",
      # A new document applies, or the participant added an optional one.
      document_added: "document_added",
      document_withdrawn: "document_withdrawn",
      # Staff discarded a signature so it can be signed again.
      document_reset: "document_reset",
      # The event's dates changed, so its waivers went out again.
      waiver_reissued: "waiver_reissued",
      guardian_replaced: "guardian_replaced",
      # A minor reached "awaiting guardian" with no guardian on file.
      guardian_missing: "guardian_missing",
      withdrawn: "withdrawn",
      rejected: "rejected",
      reinstated: "reinstated",
      # Staff set the status directly, through the API or MCP.
      staff_set: "staff_set",
      # Something wrote the status column without going through
      # #transition_to!. Recorded so the history stays complete; a new one of
      # these in app code is a bug.
      untracked: "untracked"
    }, prefix: :caused_by, validate: true

    validates :to_status, presence: true

    # The cause for a status staff picked by hand: withdrawing, rejecting and
    # undoing either have their own; anything else is just "staff set it".
    def self.staff_cause_for(to_status, from:)
      to_status = to_status.to_s
      return to_status.to_sym if ParticipantEvent::INACTIVE_STATUSES.include?(to_status)
      return :reinstated if ParticipantEvent::INACTIVE_STATUSES.include?(from.to_s)

      :staff_set
    end

    scope :chronological, -> { order(:created_at) }
  end
end
