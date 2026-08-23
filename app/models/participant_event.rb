class ParticipantEvent < ApplicationRecord
  include WalletPassUpdatable

  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :participant
  belongs_to :event
  belongs_to :nfc_badge_assigned_by, class_name: "User", optional: true
  belongs_to :um_verified_by, class_name: "User", optional: true

  # Proof that the airline UM (unaccompanied minor) service was actually booked —
  # e.g. a booking confirmation showing the UM service.
  has_one_attached :um_proof

  has_many :guardian_participant_events, dependent: :destroy
  has_many :guardians, through: :guardian_participant_events

  has_one :travel_inbound, -> { where(direction: "inbound") }, class_name: "Travel"
  has_one :travel_outbound, -> { where(direction: "outbound") }, class_name: "Travel"
  has_many :travels, dependent: :destroy

  has_one :accommodation, dependent: :destroy
  has_one :medical, dependent: :destroy
  has_one :room_assignment, dependent: :destroy
  has_one :room, through: :room_assignment
  has_many :roommate_preferences, dependent: :destroy
  has_many :roommate_exclusions, dependent: :destroy
  # The other side of the pairing — someone else naming this participant as a
  # preferred or excluded roommate also holds a foreign key to us.
  has_many :inbound_roommate_preferences, class_name: "RoommatePreference", foreign_key: :preferred_participant_event_id, dependent: :destroy, inverse_of: :preferred_participant_event
  has_many :inbound_roommate_exclusions, class_name: "RoommateExclusion", foreign_key: :excluded_participant_event_id, dependent: :destroy, inverse_of: :excluded_participant_event
  has_one :dietary, dependent: :destroy
  has_one :accessibility, dependent: :destroy
  has_one :safeguarding_info, dependent: :destroy

  has_many :emergency_contacts, dependent: :destroy
  accepts_nested_attributes_for :emergency_contacts, allow_destroy: true, reject_if: :all_blank

  has_many :consents, dependent: :destroy
  # Incidents and notes outlive the participant's enrolment — they stay on the
  # event as a safeguarding record — but the join rows pointing at us can't.
  has_many :incidents, dependent: :nullify
  has_many :notes, dependent: :nullify
  has_many :incident_participants, dependent: :destroy
  has_many :scans, dependent: :destroy
  has_many :slack_blast_recipients, dependent: :destroy
  has_many :message_deliveries, dependent: :destroy
  has_many :group_memberships, dependent: :destroy
  has_many :groups, through: :group_memberships

  enum :status, {
    invited: "invited",
    in_progress: "in_progress",
    awaiting_guardian: "awaiting_guardian",
    complete: "complete",
    withdrawn: "withdrawn",
    rejected: "rejected"
  }

  # Verification of a self-declared airline UM booking. Many participants
  # confuse "under 18 travelling alone" with the airline's paid UM service, so
  # UM is only surfaced to staff once an admin has approved the proof.
  enum :um_status, {
    none: "none",
    pending: "pending",
    approved: "approved",
    rejected: "rejected"
  }, prefix: :um

  validates :participant_id, presence: true
  validates :event_id, presence: true
  validates :participant_id, uniqueness: { scope: :event_id }
  validate :participant_not_too_old, on: :create
  validate :participant_not_banned, on: :create

  # SQL mirror of !onboarding_complete? so list filters don't have to load
  # every row into Ruby. Keep in sync with #onboarding_complete?.
  scope :missing_onboarding_data, ->(accommodation_required:, travel_required: true) {
    clauses = [
      "NOT EXISTS (SELECT 1 FROM medicals m WHERE m.participant_event_id = participant_events.id)",
      "NOT EXISTS (SELECT 1 FROM dietaries d WHERE d.participant_event_id = participant_events.id)",
      "NOT EXISTS (SELECT 1 FROM accessibilities a WHERE a.participant_event_id = participant_events.id)",
      "NOT EXISTS (SELECT 1 FROM safeguarding_infos si WHERE si.participant_event_id = participant_events.id)",
      "NOT EXISTS (SELECT 1 FROM consents c WHERE c.participant_event_id = participant_events.id)"
    ]
    if travel_required
      clauses << "NOT EXISTS (SELECT 1 FROM travels t WHERE t.participant_event_id = participant_events.id AND t.direction = 'inbound')"
      clauses << "NOT EXISTS (SELECT 1 FROM travels t WHERE t.participant_event_id = participant_events.id AND t.direction = 'outbound')"
    end
    if accommodation_required
      clauses << "NOT EXISTS (SELECT 1 FROM accommodations ac WHERE ac.participant_event_id = participant_events.id)"
    end
    where(clauses.join(" OR "))
  }



  def primary_guardian
    if guardian_participant_events.loaded?
      guardian_participant_events.find(&:is_primary_guardian)
    else
      guardian_participant_events.find_by(is_primary_guardian: true)
    end
  end

  def onboarding_complete?
    (travel_inbound.present? || !event.travel_enabled?) &&
      (travel_outbound.present? || !event.travel_enabled?) &&
      (accommodation.present? || !event.accommodation_enabled?) &&
      medical.present? &&
      dietary.present? &&
      accessibility.present? &&
      safeguarding_info.present? &&
      consents.any?
  end

  def awaiting_guardian_completion?
    onboarding_complete? && guardian_participant_events.any? { |gpe| !gpe.complete? }
  end

  def requires_guardian?
    return true unless participant.date_of_birth.present?

    participant.minor_on?(event.starts_at&.to_date || Date.current)
  end

  def age_on_event
    participant.age_on(event.starts_at&.to_date || Date.current)
  end

  def is_18_on_event?
    age_on_event == 18
  end

  def assigned_to_room?
    room_assignment.present?
  end

  def waiver_signed?
    signed_consent_of_type?("waiver")
  end

  def freedom_waiver_signed?
    signed_consent_of_type?("freedom_waiver")
  end

  def applicable_custom_documents
    @applicable_custom_documents ||= event.active_custom_documents.select { |doc| doc.applies_to?(self) }
  end

  # Every optional document on offer to this participant, added or not.
  # Relevance still applies, so an adult is never offered an under-18s-only
  # document.
  def relevant_optional_custom_documents
    event.active_custom_documents.select { |doc| doc.optional? && doc.relevant_to?(self) }
  end

  # The "Add and sign" list — on offer but not taken up.
  def available_optional_custom_documents
    relevant_optional_custom_documents.reject { |doc| opted_into_custom_document?(doc) }
  end

  # Whether the participant has taken this optional document up. Once they
  # have, it behaves exactly like any other document: signable, visible to
  # their guardian, and blocking until signed.
  def opted_into_custom_document?(custom_document)
    consent = custom_document_consent(custom_document)
    consent.present? && !consent.withdrawn?
  end

  # Where this participant stands on one optional document, for the admin
  # table's column, filter, sort and grouping. Reads the consent row that
  # records the opt-in, so it costs no extra query when consents are
  # eager-loaded. Keep in sync with Admin::ParticipantsController's SQL
  # equivalents, which have to answer the same question in the database.
  def optional_document_state(custom_document)
    consent = custom_document_consent(custom_document)
    return :not_added if consent.nil?
    return :withdrawn if consent.withdrawn?

    consent.signed? ? :signed : :awaiting
  end

  def custom_document_consent(custom_document)
    if consents.loaded?
      consents.find { |c| c.custom_document_id == custom_document.id }
    else
      consents.find_by(custom_document_id: custom_document.id)
    end
  end

  # Adding or withdrawing a document mid-request invalidates everything
  # derived from the consent set, none of which #reload touches.
  def reset_document_memoisation!
    @applicable_custom_documents = nil
    @onboarding_progress = nil
    self
  end

  def pending_custom_documents
    applicable_custom_documents.reject { |doc| custom_document_signed?(doc) }
  end

  def custom_documents_signed?
    pending_custom_documents.empty?
  end

  def custom_document_signed?(custom_document)
    if consents.loaded?
      consents.any? { |c| c.custom_document_id == custom_document.id && c.status == "signed" }
    else
      consents.where(custom_document_id: custom_document.id, status: "signed").exists?
    end
  end

  # Single source of truth for registration completion, shared by the DocuSeal
  # webhook and the guardian portal so neither path can complete a participant
  # the other would still consider blocked.
  def eligible_for_completion?
    # Signing can now happen before the participant submits their registration
    # (documents step) — never complete someone who hasn't hit submit yet.
    return false unless code_of_conduct_accepted_at.present?
    return false unless waiver_signed?
    return false unless custom_documents_signed?

    if requires_guardian?
      return false unless guardian_participant_events.any? && guardian_participant_events.all?(&:completed?)
      return false if event.freedom_waivers_enabled? && !freedom_waiver_signed?
    end

    true
  end

  def mark_complete_if_eligible!
    return false if complete?
    return false unless eligible_for_completion?

    update!(status: :complete, onboarding_completed_at: onboarding_completed_at || Time.current)
    true
  end

  # Computed display status for the UI. Maps the DB status + actual progress
  # into one of 3 user-facing labels (plus withdrawn/rejected for admin states).
  #
  # - "Awaiting Participant" — participant has steps to complete (includes invited)
  # - "Awaiting Parent"      — participant done, blocked on guardian/waiver
  # - "Complete"             — everything done
  DISPLAY_STATUSES = [ "Awaiting Participant", "Awaiting Parent", "Complete", "Withdrawn", "Rejected" ].freeze

  def display_status
    return "Withdrawn" if withdrawn?
    return "Rejected" if rejected?

    progress = onboarding_progress
    all_done = progress[:blocking_step].nil?

    return "Complete" if all_done
    return "Awaiting Parent" if blocked_on_parent?(progress)

    "Awaiting Participant"
  end

  # Returns a hash describing exactly where this participant is in the onboarding process.
  # { steps: [{ name:, done: }], blocking_step: "waiver" | nil }
  # Memoized: list views compute this several times per row. Reload the record
  # if consents/travel/etc change mid-request and a fresh answer is needed.
  def onboarding_progress
    @onboarding_progress ||= compute_onboarding_progress
  end

  def compute_onboarding_progress
    steps = []

    steps << { name: "profile", done: participant.legal_first_name.present? && participant.legal_last_name.present? && participant.date_of_birth.present? }
    steps << { name: "travel", done: travel_inbound.present? && travel_outbound.present? } if event.travel_enabled?
    steps << { name: "accommodation", done: accommodation.present? } if event.accommodation_enabled?
    steps << { name: "health", done: medical.present? && dietary.present? && accessibility.present? }

    if requires_guardian?
      steps << { name: "guardian_details", done: guardian_participant_events.any? }
      steps << { name: "guardian_portal", done: guardian_participant_events.any? && guardian_participant_events.all?(&:completed?) }
      steps << { name: "waiver", done: waiver_signed? }
      steps << { name: "freedom_waiver", done: freedom_waiver_signed? } if event.freedom_waivers_enabled?
    else
      steps << { name: "emergency_contacts", done: emergency_contacts.any? || guardian_participant_events.flat_map(&:emergency_contacts).any? }
      steps << { name: "waiver", done: waiver_signed? }
    end

    steps << { name: "custom_documents", done: custom_documents_signed? } if applicable_custom_documents.any?

    blocking = steps.find { |s| !s[:done] }

    { steps: steps, blocking_step: blocking&.dig(:name) }
  end

  def checked_in?
    if scans.loaded?
      scans.any? { |s| s.scan_context&.checks_in? }
    else
      scans.for_check_in.exists?
    end
  end

  # When the participant first checked in. Check-in is recorded as a Scan in a
  # checks_in context — scans are the only source of truth, so every reader goes
  # through here rather than at a column.
  def check_in_time
    if scans.loaded?
      scans.select { |s| s.scan_context&.checks_in? }.filter_map(&:scanned_at).min
    else
      scans.for_check_in.minimum(:scanned_at)
    end
  end

  def nfc_badge_assigned?
    nfc_badge_token.present? && nfc_badge_assigned_at.present?
  end

  def ensure_nfc_badge_token!
    return nfc_badge_token if nfc_badge_token.present?

    update!(nfc_badge_token: SecureRandom.uuid)
    nfc_badge_token
  end

  def assign_nfc_badge!(user:)
    update!(
      nfc_badge_assigned_at: Time.current,
      nfc_badge_assigned_by: user
    )
  end

  def reset_nfc_badge!
    update!(
      nfc_badge_token: SecureRandom.uuid,
      nfc_badge_assigned_at: nil,
      nfc_badge_assigned_by: nil
    )
  end

  # Self-declared airline UM service on either flight direction.
  def unaccompanied_minor_declared?
    !!((travel_inbound&.plane? && travel_inbound.is_unaccompanied_minor?) ||
      (travel_outbound&.plane? && travel_outbound.is_unaccompanied_minor?))
  end

  # Only verified UMs are surfaced to event admins and airport mode.
  def verified_unaccompanied_minor?
    unaccompanied_minor_declared? && um_approved?
  end

  # Emails the UM reviewer exactly once, and only after both pieces of
  # evidence are in: the participant's proof upload and the guardian's
  # double-confirmation of the airline booking.
  def request_um_review!
    return unless unaccompanied_minor_declared?
    return unless um_proof.attached?
    return if um_guardian_confirmed_at.blank?
    return if um_review_requested_at.present?

    update!(um_review_requested_at: Time.current)
    UmReviewMailer.review_request(participant_event: self).deliver_later
  end

  def approve_um!(user:)
    update!(um_status: :approved, um_verified_at: Time.current, um_verified_by: user)
  end

  def reject_um!(user:)
    update!(um_status: :rejected, um_verified_at: Time.current, um_verified_by: user)
  end

  def origin_airport_code
    return nil unless travel_inbound&.plane?

    travel_inbound.travel_legs.first&.departure_airport
  end

  def destination_airport_code
    return nil unless travel_inbound&.plane?

    travel_inbound.travel_legs.last&.arrival_airport
  end

  private

  # Uses the already-loaded consents when eager-loaded so per-row status
  # checks in list views don't issue a query each.
  def signed_consent_of_type?(type)
    if consents.loaded?
      consents.any? { |c| c.consent_type == type && c.status == "signed" }
    else
      consents.where(consent_type: type, status: "signed").exists?
    end
  end

  def consent_of_type(type)
    if consents.loaded?
      consents.find { |c| c.consent_type == type }
    else
      consents.find_by(consent_type: type)
    end
  end

  # True when the blocking step is something only a guardian/parent can resolve
  def blocked_on_parent?(progress)
    return false unless requires_guardian?

    blocking = progress[:blocking_step]
    return false if blocking.blank?

    case blocking
    when "guardian_portal"
      true
    when "waiver", "freedom_waiver"
      # Dual-sign: guardian signs first, then participant countersigns.
      # Once the guardian has signed, we're waiting on the participant.
      consent = consent_of_type(blocking)
      !consent&.guardian_signed?
    when "custom_documents"
      # Only "Awaiting Parent" when nothing is left for the participant to do.
      pending_custom_documents.none? do |doc|
        doc.participant_signs? && !consents.find { |c| c.custom_document_id == doc.id }&.participant_signed?
      end
    else
      false
    end
  end

  def participant_events_to_update
    [ self ]
  end

  def participant_not_too_old
    return unless participant&.date_of_birth.present? && event&.ends_at.present?

    age_at_event_end = participant.age_on(event.ends_at.to_date)
    if age_at_event_end && age_at_event_end >= 19
      errors.add(:base, "You will be 19 or older during this event. Please contact event staff for assistance.")
    end
  end

  def participant_not_banned
    return unless participant && Ban.banned?(participant.email)

    errors.add(:base, "#{participant.email} is banned from events")
  end
end
