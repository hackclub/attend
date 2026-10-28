# An organiser's invitation to apply for a visa letter, for events whose
# letters are invite-only or whose public form has closed. Separate from
# onboarding invitations: being invited to apply for a letter is not a place
# at the event.
class CreateVisaLetterInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :visa_letter_invitations, id: :uuid do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true, index: false
      t.string :email, null: false
      t.string :name
      t.string :token, null: false
      t.references :issued_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.datetime :claimed_at

      t.timestamps
    end

    add_index :visa_letter_invitations, :token, unique: true
    add_index :visa_letter_invitations, [ :event_id, :email ]
  end
end
