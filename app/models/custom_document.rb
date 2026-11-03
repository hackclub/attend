class CustomDocument < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :event
  has_many :consents, dependent: :restrict_with_error

  # The blank form participants download, print, and physically sign.
  has_one_attached :template_pdf

  enum :document_kind, {
    electronic: "electronic",
    physical: "physical"
  }

  enum :signer_type, {
    participant: "participant",
    guardian: "guardian",
    participant_and_guardian: "participant_and_guardian",
    minor_and_guardian: "minor_and_guardian"
  }, prefix: :signed_by

  validates :name, presence: true
  validates :docuseal_template_id, presence: true, if: :electronic?
  validate :template_pdf_required_for_physical

  after_create_commit :reopen_completed_participants
  # Editing who signs can hand a new blocking document to people who already
  # finished — same problem as adding one, same fix.
  # Distinct method name on purpose: registering the same symbol twice in the
  # after_commit chain replaces the create callback instead of adding to it.
  after_update_commit :reopen_completed_participants_after_edit

  scope :active, -> { where(archived_at: nil) }

  # Key used in event.docuseal_field_mappings and in docuseal_templates routes,
  # so custom documents reuse the same sync/mappings/prefill flow as waivers.
  def mapping_key
    "custom_#{id}"
  end

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def field_mapper
    Docuseal::FieldMapper.new(event: event, template_type: mapping_key)
  end

  PARTICIPANT_ROLE_PATTERN = /attendee|participant/i
  GUARDIAN_ROLE_PATTERN = /guardian|parent/i

  # The DocuSeal role an admin assigned to each Attend signer on the mappings
  # page, e.g. { "participant" => "First Party", "guardian" => "Second Party" }.
  def configured_signer_roles
    roles = event.docuseal_field_mappings&.dig(mapping_key, "signer_roles")
    roles.is_a?(Hash) ? roles.slice("participant", "guardian").compact_blank : {}
  end

  # Which template role each signer fills, as [participant_role, guardian_role].
  # A configured pick wins as long as the template still has that role; after
  # that, templates name their roles however the author liked, so match
  # loosely and fall back to role order for whoever must sign.
  def signer_roles(submitter_roles, signers: default_signers)
    configured = configured_signer_roles
    participant_role = configured["participant"].presence_in(submitter_roles)
    guardian_role = configured["guardian"].presence_in(submitter_roles)
    guardian_role = nil if guardian_role == participant_role

    participant_role ||= (submitter_roles - [ guardian_role ]).find { |r| r.match?(PARTICIPANT_ROLE_PATTERN) }
    guardian_role ||= (submitter_roles - [ participant_role ]).find { |r| r.match?(GUARDIAN_ROLE_PATTERN) }

    if signers == [ :participant ]
      participant_role ||= submitter_roles.first || "Attendee"
    elsif signers == [ :guardian ]
      guardian_role ||= submitter_roles.first || "Legal Guardian"
    else
      participant_role ||= (submitter_roles - [ guardian_role ].compact).first || "Attendee"
      guardian_role ||= (submitter_roles - [ participant_role ]).first || "Legal Guardian"
    end

    [ participant_role, guardian_role ]
  end

  # Which Attend signer a DocuSeal role name belongs to, or nil if unknown.
  # Resolves the synced template's roles the same way the submission job
  # does, so generic names ("First Party") assigned by role order still map
  # back to the right person.
  def signer_for_role(role)
    return nil if role.blank?

    roles = template_submitter_roles
    if roles.any?
      participant_role, guardian_role = signer_roles(roles)
      return :participant if participant_signs? && participant_role&.casecmp?(role)
      return :guardian if guardian_signs? && guardian_role&.casecmp?(role)
    end

    configured = configured_signer_roles.find { |_, name| name.casecmp?(role) }&.first
    return configured.to_sym if configured

    self.class.signer_for_role_name(role)
  end

  # Classifies a role purely by its name ("Attendee", "Parent/Guardian").
  def self.signer_for_role_name(role)
    if role.to_s.match?(PARTICIPANT_ROLE_PATTERN)
      :participant
    elsif role.to_s.match?(GUARDIAN_ROLE_PATTERN)
      :guardian
    end
  end

  # Role names from the last template sync on the mappings page.
  def template_submitter_roles
    submitters = event.docuseal_field_mappings&.dig(mapping_key, "template_snapshot", "submitters")
    Array(submitters).filter_map { |s| s["name"].presence if s.is_a?(Hash) }
  end

  def default_signers
    [ (:participant if participant_signs?), (:guardian if guardian_signs?) ].compact
  end

  # Both must sign for the dual-signer types.
  def participant_signs?
    signed_by_participant? || signed_by_participant_and_guardian? || signed_by_minor_and_guardian?
  end

  def guardian_signs?
    signed_by_guardian? || signed_by_participant_and_guardian? || signed_by_minor_and_guardian?
  end

  # Whether this document is live for a participant — the single gate every
  # surface goes through (wizard, dashboard, guardian portal, completion,
  # reopen job). An optional document doesn't exist for anyone until that
  # participant adds it, which is what keeps an opt-in activity's waiver off
  # the guardian's portal entirely.
  def applies_to?(participant_event)
    return false if optional? && !participant_event.opted_into_custom_document?(self)

    relevant_to?(participant_event)
  end

  # Whether the document is meant for this participant at all, ignoring
  # opt-in. Guardian-only documents only make sense for participants who have
  # a guardian, and minor_and_guardian documents are skipped entirely for
  # adults; every other document applies to everyone (adults sign
  # participant_and_guardian documents alone).
  def relevant_to?(participant_event)
    if signed_by_guardian? || signed_by_minor_and_guardian?
      return participant_event.requires_guardian?
    end
    true
  end

  # Physical documents are signed on paper: the participant uploads a photo of
  # the signed form, and for minors the guardian then reviews and confirms it.
  def guardian_verifies?(participant_event)
    physical? && guardian_signs? && participant_event.requires_guardian?
  end

  private

  # Only signer_type and optional decide who the document applies to; renaming
  # it or swapping the template doesn't change the audience.
  # reopen_completed_participants ignores optional documents itself, so a
  # required → optional flip stops short of the job.
  def reopen_completed_participants_after_edit
    return unless saved_change_to_signer_type? || saved_change_to_optional?

    reopen_completed_participants
  end

  # Participants who finished onboarding before this document existed now have
  # a new blocking step — reopen them so their db status matches. While
  # guardian invites are locked, documents aren't signable, so the reopen
  # waits for unlock (Event#send_pending_guardian_invites re-enqueues it).
  def reopen_completed_participants
    # Optional documents block nobody until they're added, so adding one to
    # the event must not disturb participants who already finished.
    return if optional?
    return if event.guardian_invites_locked?

    ReopenParticipantsForCustomDocumentsJob.perform_later(event_id)
  end

  def template_pdf_required_for_physical
    return unless physical?

    unless template_pdf.attached?
      errors.add(:template_pdf, "must be uploaded for a physical document")
      return
    end

    unless template_pdf.content_type == "application/pdf"
      errors.add(:template_pdf, "must be a PDF")
      return
    end

    if template_pdf.blob.byte_size > 25.megabytes
      errors.add(:template_pdf, "must be less than 25MB")
      return
    end

    parse_template_pdf
  end

  # Actually parse the bytes — the declared content type is just a claim. Only
  # runs when the attachment changed, so routine saves never download the blob.
  # Stores the page count so uploads of the signed form can be capped to it.
  def parse_template_pdf
    change = attachment_changes["template_pdf"]
    return unless change

    bytes = uploadable_bytes(change.attachable)
    page_count = PDF::Reader.new(StringIO.new(bytes)).page_count

    if page_count.zero?
      errors.add(:template_pdf, "must be a valid PDF")
    else
      self.template_page_count = page_count
    end
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, ArgumentError
    errors.add(:template_pdf, "must be a valid PDF")
  end

  def uploadable_bytes(attachable)
    case attachable
    when Hash
      io = attachable.fetch(:io)
      io.rewind
      io.read.tap { io.rewind }
    when ActiveStorage::Blob
      attachable.download
    else
      attachable.rewind if attachable.respond_to?(:rewind)
      attachable.read.tap { attachable.rewind if attachable.respond_to?(:rewind) }
    end
  end
end
