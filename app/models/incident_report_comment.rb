class IncidentReportComment < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  encrypts :body

  belongs_to :incident_report
  belongs_to :user, optional: true

  has_many_attached :attachments

  MAX_ATTACHMENT_BYTE_SIZE = 25.megabytes
  MAX_ATTACHMENT_COUNT = 10

  validates :body, presence: true

  validate :acceptable_attachments

  attr_accessor :skip_status_callback

  after_create :update_incident_report_status, if: -> { new_status.present? }

  private

  def acceptable_attachments
    return unless attachments.attached?

    if attachments.count > MAX_ATTACHMENT_COUNT
      errors.add(:attachments, "can include at most #{MAX_ATTACHMENT_COUNT} files")
    end

    attachments.each do |attachment|
      next unless attachment.byte_size > MAX_ATTACHMENT_BYTE_SIZE

      errors.add(:attachments, "#{attachment.filename} is too large (max 25MB per file)")
    end
  end

  # A status change must not depend on the whole report still passing
  # validation: reports filed before today's phone/email rules can be invalid
  # as stored, and `update!` raising inside this callback makes `save` return
  # false with no error on the comment (a blank 422 for the admin). Only the
  # status is changing, so skip validations and keep timestamps/versions.
  def update_incident_report_status
    incident_report.status = new_status
    incident_report.save!(validate: false)
  end
end
