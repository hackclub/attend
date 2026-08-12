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

  def update_incident_report_status
    incident_report.update!(status: new_status)
  end
end
