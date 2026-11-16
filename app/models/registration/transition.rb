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
      # A check with no more specific reason found the registration had
      # everything (a backlog task, an explicit re-check).
      requirements_met: "requirements_met",
      # A new document applies, or the participant added an optional one.
      document_added: "document_added",
      document_withdrawn: "document_withdrawn",
      # Staff discarded a signature so it can be signed again.
      document_reset: "document_reset",
      # The event's dates changed, so its waivers went out again.
      waiver_reissued: "waiver_reissued",
      guardian_replaced: "guardian_replaced",
      # A record the requirements read changed, with nothing more specific
      # known: an answer (travel, health, contacts), a consent, a guardian.
      data_changed: "data_changed",
      documents_changed: "documents_changed",
      guardian_changed: "guardian_changed",
      # The event switched a module on or off, or moved its dates.
      settings_changed: "settings_changed",
      withdrawn: "withdrawn",
      rejected: "rejected",
      reinstated: "reinstated",
      # `rake registration:sync` brought a status in line with requirements.
      backfill: "backfill",
      # Something wrote the status column without going through
      # #transition_to!. Recorded so the history stays complete; a new one of
      # these in app code is a bug.
      untracked: "untracked"
    }, prefix: :caused_by, validate: true

    validates :to_status, presence: true

    scope :chronological, -> { order(:created_at) }
  end
end
