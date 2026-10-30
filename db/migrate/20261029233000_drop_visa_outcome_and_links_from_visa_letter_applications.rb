# Visa letter applications stopped recording the visa outcome, and stopped
# storing links to the person's registration and invitation:
# VisaLetterApplication#registration finds those from the event and the
# applicant instead. The model has ignored these columns since that release,
# so no running pod reads or writes them any more.
#
# `if_exists` because a shared dev database may already have lost them to an
# earlier version of that change. Dropping a column drops its index with it.
class DropVisaOutcomeAndLinksFromVisaLetterApplications < ActiveRecord::Migration[8.1]
  def up
    remove_reference :visa_letter_applications, :participant_event, foreign_key: true, if_exists: true
    remove_reference :visa_letter_applications, :invitation, foreign_key: true, if_exists: true
    remove_column :visa_letter_applications, :visa_outcome, if_exists: true
    remove_column :visa_letter_applications, :visa_outcome_recorded_at, if_exists: true
  end

  # Brings the columns back empty: the old links and outcomes are gone.
  def down
    add_reference :visa_letter_applications, :participant_event, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
    add_reference :visa_letter_applications, :invitation, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
    add_column :visa_letter_applications, :visa_outcome, :string, null: false, default: "unknown"
    add_column :visa_letter_applications, :visa_outcome_recorded_at, :datetime
  end
end
