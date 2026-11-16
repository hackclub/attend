module Registration
  # The one list of what a registration needs before it is complete, and who
  # each item is waiting on.
  #
  # ParticipantEvent's status column follows this through #sync_status!, and
  # #onboarding_progress and #eligible_for_completion? read it too, so the
  # status, the badge and the list of what's outstanding can't disagree.
  class Requirements
    # kind:  :data (something the participant fills in), :submission (the code
    #        of conduct, which is what "submitted" means) or :document
    #        (signatures and the guardian portal).
    # owner: who has to act next for this to be met, :participant or :guardian.
    Requirement = Data.define(:key, :kind, :owner, :met) do
      def met? = met
      def unmet? = !met
    end

    attr_reader :participant_event

    def initialize(participant_event)
      @participant_event = participant_event
    end

    # Every requirement that applies to this registration, in the order the
    # participant meets them.
    def all
      @all ||= build
    end

    def unmet
      all.select(&:unmet?)
    end

    # The first unmet requirement: what the registration is stuck on.
    def blocking
      all.find(&:unmet?)
    end

    def met?
      blocking.nil?
    end

    # Whether the registration has everything.
    #
    # ignoring_submission: "would it, if the participant hit submit?"
    def completable?(ignoring_submission: false)
      return false if closed?

      all.none? { |r| r.unmet? && !(ignoring_submission && r.kind == :submission) }
    end

    # :participant, :guardian, or nil when nothing is outstanding.
    def waiting_on
      blocking&.owner
    end

    # The value the status column should hold. ParticipantEvent#sync_status!
    # is what writes it.
    #
    # Withdrawn and rejected are staff decisions and stay put. A registration
    # for an event that has ended is frozen as it stands. Otherwise the status
    # follows the requirements, except that a complete registration isn't
    # reopened by something it can't act on yet (see #deferred?).
    def stage(now: Time.current)
      return pe.status if closed? || event_ended?(now)

      computed_stage(now: now)
    end

    # #stage without the freeze on ended events, so reports can show how far
    # past events have drifted even though they're left alone.
    def computed_stage(now: Time.current)
      return pe.status if closed?
      # Opening the wizard is what moves someone on from invited
      # (OnboardingController). Imported data can meet every other
      # requirement, but until they've been in they haven't started.
      return "invited" if pe.invited?
      return "complete" if met?
      return "complete" if pe.complete? && unmet.all? { |r| deferred?(r, now) }
      return "awaiting_guardian" if waiting_on == :guardian

      "in_progress"
    end

    # Same shape as ParticipantEvent#onboarding_progress.
    def progress
      {
        steps: all.map { |r| { name: r.key, done: r.met? } },
        blocking_step: blocking&.key
      }
    end

    private

    def pe = participant_event
    def event = pe.event

    def closed?
      pe.withdrawn? || pe.rejected?
    end

    def event_started?(now)
      event.starts_at.present? && event.starts_at <= now
    end

    def event_ended?(now)
      event.ends_at.present? && event.ends_at < now
    end

    # Whether an unmet requirement should leave a complete registration alone
    # for now:
    # - data, once the event has started. Missing answers reopen a
    #   registration beforehand, but not someone already at the door.
    # - a new document while guardian invites are locked. Nobody can sign it
    #   yet; ReopenParticipantsForCustomDocumentsJob reopens and emails them
    #   when the lock lifts.
    def deferred?(requirement, now)
      return event_started?(now) if requirement.kind == :data
      return event.guardian_invites_locked? if requirement.key == "custom_documents"

      false
    end

    def build
      list = []
      participant = pe.participant

      list << data("profile", participant.legal_first_name.present? && participant.legal_last_name.present? && participant.date_of_birth.present?)
      list << data("travel", pe.travel_inbound.present? && pe.travel_outbound.present?) if event.travel_enabled?
      list << data("accommodation", pe.accommodation.present?) if event.accommodation_enabled?
      list << data("health", pe.medical.present? && pe.dietary.present? && pe.accessibility.present?)
      # Sits before the guardian's part because the guardian isn't invited
      # until the participant has submitted.
      list << requirement("code_of_conduct", :submission, :participant, pe.code_of_conduct_accepted_at.present?)

      guardians = pe.guardian_participant_events
      if pe.requires_guardian?
        list << data("guardian_details", guardians.any?)
        list << requirement("guardian_portal", :document, :guardian, guardians.any? && guardians.all?(&:completed?))
        list << dual_signed("waiver", pe.waiver_signed?)
        list << dual_signed("freedom_waiver", pe.freedom_waiver_signed?) if event.freedom_waivers_enabled?
      else
        list << data("emergency_contacts", pe.emergency_contacts.any? || guardians.flat_map(&:emergency_contacts).any?)
        list << requirement("waiver", :document, :participant, pe.waiver_signed?)
      end

      if pe.applicable_custom_documents.any?
        list << requirement("custom_documents", :document, custom_documents_owner, pe.custom_documents_signed?)
      end

      list
    end

    def requirement(key, kind, owner, met)
      Requirement.new(key: key, kind: kind, owner: owner, met: met ? true : false)
    end

    def data(key, met)
      requirement(key, :data, :participant, met)
    end

    # A minor's waivers are signed by the guardian first, then countersigned
    # by the participant. Until the guardian has signed, it's theirs to do.
    def dual_signed(type, signed)
      guardian_signed = pe.consent_of_type(type)&.guardian_signed?
      requirement(type, :document, guardian_signed ? :participant : :guardian, signed)
    end

    # Only the guardian's while nothing is left for the participant to sign.
    def custom_documents_owner
      return :participant unless pe.requires_guardian?

      participant_owes = pe.pending_custom_documents.any? do |doc|
        doc.participant_signs? && !pe.custom_document_consent(doc)&.participant_signed?
      end
      participant_owes ? :participant : :guardian
    end
  end
end
