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

  # Both must sign for the dual-signer types.
  def participant_signs?
    signed_by_participant? || signed_by_participant_and_guardian? || signed_by_minor_and_guardian?
  end

  def guardian_signs?
    signed_by_guardian? || signed_by_participant_and_guardian? || signed_by_minor_and_guardian?
  end

  # Guardian-only documents only make sense for participants who have a
  # guardian, and minor_and_guardian documents are skipped entirely for
  # adults; every other document applies to everyone (adults sign
  # participant_and_guardian documents alone).
  def applies_to?(participant_event)
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

  # Participants who finished onboarding before this document existed now have
  # a new blocking step — reopen them so their db status matches. While
  # guardian invites are locked, documents aren't signable, so the reopen
  # waits for unlock (Event#send_pending_guardian_invites re-enqueues it).
  def reopen_completed_participants
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
