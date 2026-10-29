# Attend no longer tracks what the embassy decided on a visa letter. Whether
# someone gets a place is the event's own invitation, and their visa status
# for travel is what they enter in onboarding.
class RemoveVisaOutcomeFromVisaLetterApplications < ActiveRecord::Migration[8.1]
  def change
    remove_column :visa_letter_applications, :visa_outcome, :string, null: false, default: "unknown"
    remove_column :visa_letter_applications, :visa_outcome_recorded_at, :datetime
  end
end
