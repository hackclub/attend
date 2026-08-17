class Consent < ApplicationRecord
  include WalletPassUpdatable

  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :participant_event
  belongs_to :guardian_participant_event, optional: true
  belongs_to :custom_document, optional: true

  # Photos (or a scan) of a physically signed custom document, uploaded by
  # whoever signed it on paper.
  has_many_attached :physical_uploads
  has_one :participant, through: :participant_event
  has_one :event, through: :participant_event
  has_one :guardian, through: :guardian_participant_event

  enum :consent_type, {
    event_consent: "event_consent",
    medical_release: "medical_release",
    code_of_conduct: "code_of_conduct",
    media: "media",
    waiver: "waiver",
    participant_agreement: "participant_agreement",
    freedom_waiver: "freedom_waiver",
    custom_document: "custom_document"
  }

  enum :status, {
    pending: "pending",
    sent: "sent",
    viewed: "viewed",
    signed: "signed",
    voided: "voided",
    failed: "failed"
  }

  REQUIRED_CONSENT_TYPES = %w[code_of_conduct waiver freedom_waiver].freeze

  validates :participant_event_id, presence: true
  validates :consent_type, presence: true
  validates :custom_document, presence: true, if: :custom_document?
  validates :custom_document_id, uniqueness: { scope: :participant_event_id }, allow_nil: true

  before_validation :inherit_docuseal_host_from_event, on: :create, if: -> { docuseal_host.blank? }

  scope :required, -> { where(consent_type: REQUIRED_CONSENT_TYPES) }
  scope :signed, -> { where(status: :signed) }

  def signed?
    status == "signed"
  end

  def display_name
    return custom_document.name if custom_document
    consent_type.titleize
  end

  def requires_signature?
    %w[pending sent viewed].include?(status)
  end

  def guardian_signing_url
    return nil unless docuseal_guardian_slug.present?
    Docuseal.signing_url(docuseal_guardian_slug, host: docuseal_host)
  end

  def participant_signing_url
    return nil unless docuseal_participant_slug.present?
    Docuseal.signing_url(docuseal_participant_slug, host: docuseal_host)
  end

  def guardian_signed?
    guardian_signed_at.present?
  end

  # The participant's own part is done — either they've signed their portion
  # of a dual-signer document, or the document is fully signed.
  def participant_portion_signed?
    signed? || participant_signed?
  end

  # Pull signature state straight from the DocuSeal API. Normally webhooks
  # keep consents up to date; this covers the gap right after an embedded
  # form fires "completed" (and environments webhooks can't reach).
  def sync_from_docuseal!
    return if docuseal_envelope_id.blank?

    submission = Docuseal::Client.for(self).get_submission(docuseal_envelope_id)
    submitters = submission["submitters"] || []

    participant_submitter = submitters.find { |s| s["slug"] == docuseal_participant_slug }
    guardian_submitter = submitters.find { |s| s["slug"] == docuseal_guardian_slug }

    updates = {}
    if participant_signed_at.blank? && participant_submitter&.dig("completed_at").present?
      updates[:participant_signed_at] = Time.zone.parse(participant_submitter["completed_at"])
    end
    if guardian_signed_at.blank? && guardian_submitter&.dig("completed_at").present?
      updates[:guardian_signed_at] = Time.zone.parse(guardian_submitter["completed_at"])
    end

    if submitters.any? && submitters.all? { |s| s["completed_at"].present? }
      updates[:status] = :signed unless signed?
      updates[:signed_at] = Time.current if signed_at.blank?
      updates[:pending_on] = nil
    elsif updates[:participant_signed_at] && guardian_signed_at.blank?
      updates[:pending_on] = "guardian"
    end

    update!(updates) if updates.any?
    participant_event&.mark_complete_if_eligible! if signed?
  rescue Docuseal::Error, ArgumentError => e
    # ArgumentError covers environments with no DocuSeal credentials configured
    Rails.logger.warn("[Docuseal] sync_from_docuseal! failed for consent #{id}: #{e.message}")
  end

  def participant_signed?
    participant_signed_at.present?
  end

  def physical_document?
    custom_document&.physical? || false
  end

  # Opt-in bookkeeping for optional custom documents. The consent row itself
  # is the opt-in — a participant who never added the document has no row —
  # and backing out sets withdrawn_at rather than destroying the row, so a
  # signature already collected stays on file as a record.
  def withdrawn?
    withdrawn_at.present?
  end

  def withdraw!
    return if withdrawn?

    update!(withdrawn_at: Time.current)
  end

  # Re-adding a document the participant previously backed out of. Anything
  # already signed still counts — there's no reason to make them sign twice.
  def reinstate!
    update!(withdrawn_at: nil, opted_in_at: opted_in_at || Time.current)
  end

  def physical_uploaded?
    physical_uploads.attached?
  end

  def awaiting_guardian_verification?
    physical_document? && physical_uploaded? && !signed? && !failed?
  end

  # The participant uploaded a photo of the physically signed form. For minors
  # on a guardian-co-signed document the consent stays open until the guardian
  # reviews the photo and confirms it; everyone else is done immediately.
  def mark_physical_uploaded_by_participant!
    return if signed?

    now = Time.current
    updates = {
      participant_signed_at: participant_signed_at || now,
      sent_at: sent_at || now
    }

    if custom_document.guardian_verifies?(participant_event)
      updates[:status] = :sent
      updates[:pending_on] = "guardian"
    else
      updates[:status] = :signed
      updates[:signed_at] = now
      updates[:pending_on] = nil
    end

    update!(updates)
    participant_event.mark_complete_if_eligible! if signed?
  end

  # A guardian uploaded the signed form themselves (guardian-only documents) —
  # the upload is the confirmation, so the consent completes right away.
  def mark_physical_uploaded_by_guardian!(guardian_participant_event)
    return if signed?

    now = Time.current
    update!(
      guardian_participant_event: self.guardian_participant_event || guardian_participant_event,
      guardian_signed_at: guardian_signed_at || now,
      sent_at: sent_at || now,
      signed_at: signed_at || now,
      status: :signed,
      pending_on: nil
    )
    participant_event.mark_complete_if_eligible!
  end

  # Every upload was removed before the document was confirmed — wind the
  # consent back to pending so it doesn't sit claiming a signature (or waiting
  # on a guardian) with nothing attached. Never touches signed consents.
  def reset_physical_upload_state!
    return unless physical_document?
    return if signed?

    update!(status: :pending, participant_signed_at: nil, pending_on: nil, sent_at: nil)
  end

  # The guardian reviewed the uploaded photo and confirmed the physically
  # signed document is accurate and complete.
  def verify_physical_upload!(guardian_participant_event)
    now = Time.current
    update!(
      guardian_participant_event: self.guardian_participant_event || guardian_participant_event,
      guardian_signed_at: guardian_signed_at || now,
      signed_at: now,
      status: :signed,
      pending_on: nil
    )
    participant_event.mark_complete_if_eligible!
  end

  private

  def participant_events_to_update
    [ participant_event ].compact
  end

  def inherit_docuseal_host_from_event
    self.docuseal_host = event&.docuseal_host || Docuseal::HostConfig.default_host
  end
end
