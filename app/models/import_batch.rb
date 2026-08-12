class ImportBatch < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :event

  enum :status, {
    pending: "pending",
    previewing: "previewing",
    importing: "importing",
    sending_invites: "sending_invites",
    completed: "completed",
    failed: "failed"
  }

  validates :total_count, numericality: { greater_than_or_equal_to: 0 }
  validates :imported_count, numericality: { greater_than_or_equal_to: 0 }
  validates :skipped_count, numericality: { greater_than_or_equal_to: 0 }
  validates :error_count, numericality: { greater_than_or_equal_to: 0 }
  validates :invites_sent_count, numericality: { greater_than_or_equal_to: 0 }

  def progress_percentage
    return 0 if total_count.zero?

    case status
    when "importing"
      ((imported_count + skipped_count + error_count).to_f / total_count * 50).round
    when "sending_invites"
      base = 50
      invites_to_send = send_invitations ? imported_count : 0
      return 100 if invites_to_send.zero?
      base + ((invites_sent_count.to_f / invites_to_send) * 50).round
    when "completed"
      100
    else
      0
    end
  end

  def current_status_message
    case status
    when "pending"
      "Waiting to start..."
    when "previewing"
      "Ready for review"
    when "importing"
      "Importing participants (#{imported_count + skipped_count}/#{total_count})..."
    when "sending_invites"
      invites_to_send = imported_count
      "Sending invitations (#{invites_sent_count}/#{invites_to_send})..."
    when "completed"
      "Import completed"
    when "failed"
      "Import failed"
    else
      "Unknown status"
    end
  end

  def broadcast_progress
    ActionCable.server.broadcast(
      "import_batch_#{id}",
      {
        status: status,
        progress_percentage: progress_percentage,
        status_message: current_status_message,
        imported_count: imported_count,
        skipped_count: skipped_count,
        error_count: error_count,
        invites_sent_count: invites_sent_count,
        total_count: total_count,
        errors: errors_data.last(10),
        completed: completed?
      }
    )
  rescue => e
    Rails.logger.error("[ImportBatch#broadcast_progress] Failed to broadcast: #{e.message}")
  end
end
