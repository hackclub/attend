# A visa letter application finds the person's registration by their Hack
# Club account or email (VisaLetterApplication#registration), whichever came
# first, so it no longer stores one. Places come from the event's own
# invitations, so it doesn't store an invitation either.
class RemoveRegistrationLinksFromVisaLetterApplications < ActiveRecord::Migration[8.1]
  def change
    remove_reference :visa_letter_applications, :participant_event, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
    remove_reference :visa_letter_applications, :invitation, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
  end
end
