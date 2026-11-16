module Registration
  # The one list of what a registration needs before it is complete, and who
  # each item is waiting on.
  #
  # Today three places answer that question and disagree:
  # ParticipantEvent#compute_onboarding_progress (the badge),
  # #eligible_for_completion? (the status column) and #onboarding_complete?
  # (list filters). This is the replacement for all three. For now it runs in
  # shadow: nothing reads it except `rake registration:shadow`, which reports
  # where it and the stored status disagree.
  #
  # #progress and #display_status are a faithful port of the model's current
  # behaviour (the spec holds them equal). #stage is the new part: the value
  # the status column should hold.
  class Requirements
    # kind:  :data (something the participant fills in), :submission (the code
    #        of conduct, which is what "submitted" means) or :document
    #        (signatures and the guardian portal).
    # owner: who has to act next for this to be met, :participant or :guardian.
    Requirement = Data.define(:key, :kind, :owner, :met) do
      def met? = met
      def unmet? = !met
    end

    DISPLAY = {
      complete: "Complete",
      guardian: "Awaiting Parent",
      participant: "Awaiting Participant"
    }.freeze

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

    # :participant, :guardian, or nil when nothing is outstanding.
    def waiting_on
      blocking&.owner
    end

    # The value the status column should hold.
    #
    # Withdrawn and rejected are staff decisions and stay put. A registration
    # for an event that has ended is frozen as it stands. Otherwise the status
    # follows the requirements, with one exception: once the event has
    # started, a complete registration is only reopened by a document or
    # submission going missing, never by data alone.
    def stage(now: Time.current)
      return pe.status if closed? || event_ended?(now)

      computed_stage(now: now)
    end

    # #stage without the freeze on ended events, so the shadow report can show
    # how far past events have drifted even though they'll be left alone.
    def computed_stage(now: Time.current)
      return pe.status if closed?
      return "complete" if met?
      return "complete" if pe.complete? && event_started?(now) && unmet.all? { |r| r.kind == :data }
      return "invited" if pe.invited?
      return "awaiting_guardian" if waiting_on == :guardian

      "in_progress"
    end

    # Same labels as ParticipantEvent#display_status.
    def display_status
      return "Withdrawn" if pe.withdrawn?
      return "Rejected" if pe.rejected?

      DISPLAY.fetch(waiting_on || :complete)
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
      guardian_signed = pe.consents.find { |c| c.consent_type == type }&.guardian_signed?
      requirement(type, :document, guardian_signed ? :participant : :guardian, signed)
    end

    # Only the guardian's while nothing is left for the participant to sign.
    def custom_documents_owner
      return :participant unless pe.requires_guardian?

      participant_owes = pe.pending_custom_documents.any? do |doc|
        doc.participant_signs? && !pe.consents.find { |c| c.custom_document_id == doc.id }&.participant_signed?
      end
      participant_owes ? :participant : :guardian
    end
  end
end
