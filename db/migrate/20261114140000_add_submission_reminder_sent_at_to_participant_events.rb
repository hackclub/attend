# Stamped when we email a participant whose registration is only waiting on
# their own submit (code of conduct), so the reminder goes out once.
class AddSubmissionReminderSentAtToParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_events, :submission_reminder_sent_at, :datetime
  end
end
