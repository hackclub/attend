module Docuseal
  # An event's dates moved after waivers went out (Event#waiver_dates_stale?).
  # Templates cloned by DefaultTemplateSetup have the old dates printed on
  # them, and every submission snapshots its template, so fixing it takes two
  # steps: re-clone those templates with the new dates, then void each issued
  # waiver and re-issue it on the new template, emailing whoever has to sign.
  #
  # Custom templates (an organizer's own DocuSeal template) aren't ours to
  # rewrite — they're reported so someone can fix the dates by hand before the
  # waivers are re-issued.
  class WaiverDateRegeneration
    # adult_waiver has no blueprint, so it's only ever reported (as custom).
    TEMPLATE_TYPES = %w[waiver freedom_waiver adult_waiver].freeze
    WAIVER_CONSENT_TYPES = %w[waiver freedom_waiver].freeze

    Template = Struct.new(:template_type, :template_id, :status, keyword_init: true) do
      def regenerable?
        status == :default
      end

      def label
        template_type.humanize
      end
    end

    def initialize(event)
      @event = event
    end

    # The event's waiver templates and whether we can regenerate each one:
    # :default (cloned by Attend — regenerable), :custom, or :unknown when
    # DocuSeal couldn't be reached to tell.
    def templates
      @templates ||= TEMPLATE_TYPES.filter_map do |template_type|
        template_id = template_id_in_use(template_type)
        next if template_id.blank?

        Template.new(template_type: template_type, template_id: template_id, status: template_status(template_type, template_id))
      end
    end

    # We couldn't tell whether some template is ours, so regenerating now
    # might leave old dates on a template we should have re-cloned.
    def blocked?
      templates.any? { |template| template.status == :unknown }
    end

    # Re-clones every default template with the event's current dates. Field
    # mappings carry over untouched — the clone comes from the same blueprint,
    # so its field names are identical. Raises Docuseal::Error on failure.
    def regenerate_templates!
      raise Docuseal::Error, "couldn't check which waiver templates Attend created" if blocked?

      templates.select(&:regenerable?).each do |template|
        DefaultTemplateSetup.new(@event).refresh_dates(template.template_type)
      end
    end

    # Issued waivers (a DocuSeal submission exists) for participants still
    # attending, grouped by participant_event.
    def consents_to_reissue(include_signed:)
      scope = Consent
        .joins(:participant_event)
        .where(participant_events: { event_id: @event.id })
        .where.not(participant_events: { status: %w[withdrawn rejected] })
        .where(consent_type: WAIVER_CONSENT_TYPES)
        .where.not(docuseal_envelope_id: nil)
        .where.not(status: :voided)
      scope = scope.where.not(status: :signed) unless include_signed
      scope
    end

    def people_count(include_signed:)
      consents_to_reissue(include_signed: include_signed).distinct.count(:participant_event_id)
    end

    # Voids each of the participant's stale waivers, re-issues it on the
    # event's current template, and emails whoever has to sign it again.
    #
    # Order matters: the DocuSeal archive calls go first (external and best
    # effort), then every db change in one transaction, and only once that has
    # committed do the create jobs and emails go out. So if anything in the
    # transaction raises, this participant's consents are untouched and nobody
    # is emailed about a waiver that was never re-issued. (Active Job here
    # doesn't defer enqueues to commit, hence doing it by hand.)
    def reissue!(participant_event, consents)
      reissues = consents.filter_map { |consent| plan_reissue(participant_event, consent) }
      return false if reissues.empty?

      reissues.each { |reissue| void_submission(reissue.consent) }

      guardian_participant_events = reissues.filter_map(&:guardian_participant_event).uniq

      ActiveRecord::Base.transaction do
        reissues.each { |reissue| reissue.consent.reset_for_reissue!(docuseal_host: @event.docuseal_host) }

        # A signed waiver going back to pending is a new blocking step, so the
        # db status has to follow the live display (see
        # ReopenParticipantsForCustomDocumentsJob for the same move).
        participant_event.update!(status: :in_progress) if participant_event.complete?
        participant_event.reopen_guardian_portal_access!(guardian_participant_events)
      end

      reissues.each { |reissue| enqueue_submission(reissue) }
      send_emails(participant_event, reissues)
      true
    end

    private

    # One waiver to re-issue, with the guardian who signs it (nil when the
    # participant signs alone).
    Reissue = Struct.new(:consent, :guardian_participant_event, keyword_init: true) do
      def guardian_flow?
        guardian_participant_event.present?
      end
    end

    # Whether a waiver goes out the minor (guardian co-signs) or adult way is
    # decided by how it was first issued, not by the participant's age on the
    # event's new start date — moving the dates mustn't flip someone between
    # flows mid-way. Freedom waivers are always guardian-signed.
    def plan_reissue(participant_event, consent)
      guardian_issued = consent.freedom_waiver? ||
        consent.guardian_participant_event_id.present? ||
        consent.docuseal_guardian_slug.present?
      return Reissue.new(consent: consent) unless guardian_issued

      guardian_participant_event = consent.signing_guardian_participant_event
      if guardian_participant_event.nil?
        # CreateMinorWaiverJob/CreateFreedomWaiverJob can't issue anything
        # without a guardian, so voiding this one would leave them with no
        # waiver at all. Leave it be for someone to sort out by hand.
        Rails.logger.warn(
          "[WaiverDateRegeneration] Skipping #{consent.consent_type} consent #{consent.id} for participant_event #{participant_event.id}: no guardian to re-issue it to"
        )
        return
      end

      Reissue.new(consent: consent, guardian_participant_event: guardian_participant_event)
    end

    # adult_waiver only counts when it's what adults actually get, mirroring
    # CreateAdultWaiverJob#template_id_for: the event's waiver template wins.
    def template_id_in_use(template_type)
      return if template_type == "adult_waiver" && @event.docuseal_waiver_template_id.present?

      @event.public_send(DefaultTemplateSetup::TEMPLATE_COLUMNS.fetch(template_type)).presence
    end

    def template_status(template_type, template_id)
      # Attend can only have cloned templates that have a blueprint.
      return :custom unless DefaultTemplateSetup::BLUEPRINT_IDS.key?(template_type)

      template = Client.for(@event).get_template(template_id)
      template["external_id"] == DefaultTemplateSetup.external_id_for(@event, template_type) ? :default : :custom
    rescue Docuseal::Error, Faraday::Error, ArgumentError => e
      # ArgumentError covers environments with no DocuSeal credentials configured
      Rails.logger.warn("[WaiverDateRegeneration] Couldn't fetch template #{template_id} for event #{@event.id}: #{e.message}")
      :unknown
    end

    # Best effort: the point is to stop the old link (with the old dates)
    # working, but a DocuSeal failure mustn't block re-issuing the waiver.
    def void_submission(consent)
      Client.for(consent).archive_submission(consent.docuseal_envelope_id)
    rescue Docuseal::Error, Faraday::Error, ArgumentError => e
      Rails.logger.warn(
        "[WaiverDateRegeneration] Couldn't archive DocuSeal submission #{consent.docuseal_envelope_id} for consent #{consent.id}: #{e.message}"
      )
    end

    def enqueue_submission(reissue)
      consent = reissue.consent
      if consent.freedom_waiver?
        DocusealJobs::CreateFreedomWaiverJob.perform_later(consent.id)
      elsif reissue.guardian_flow?
        # Emails the teen their signing link once the submission exists.
        DocusealJobs::CreateMinorWaiverJob.perform_later(consent.id, dates_changed: true)
      else
        DocusealJobs::CreateAdultWaiverJob.perform_later(consent.id)
      end
    end

    # One email per person, however many of their waivers were re-issued.
    # Each guardian hears about the waivers that are theirs to sign. A minor's
    # own email comes from CreateMinorWaiverJob, which has their signing link;
    # adults sign on the waiver page, so they're emailed here.
    def send_emails(participant_event, reissues)
      reissues.select(&:guardian_flow?).group_by(&:guardian_participant_event).each do |guardian_participant_event, guardian_reissues|
        GuardianMailer.waiver_dates_changed(
          guardian_participant_event: guardian_participant_event,
          waiver_types: guardian_reissues.map { |reissue| reissue.consent.consent_type.to_sym }.uniq
        ).deliver_later
      end

      if reissues.any? { |reissue| !reissue.guardian_flow? }
        ParticipantMailer.waiver_dates_changed(participant_event: participant_event).deliver_later
      end
    end
  end
end
