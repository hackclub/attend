# Someone asking for a visa invitation letter to an event. The letter comes
# before a place: applicants who are turned down, or whose visa is refused,
# never become participants, so this hangs off the event rather than a
# registration. `participant_event_id` is filled in when they already have a
# place, or once staff offer them one.
#
# The applicant's details are a copy, taken when they apply and frozen once
# the letter is issued, as are the `letter_*` event details: embassies check
# letters against /verify, which has to keep saying what the letter says
# however the event is edited later. Rows imported from Envoy have no user
# until their owner signs in, and keep Envoy's ids, reference numbers and
# verification codes so old links and printed codes still resolve.
class CreateVisaLetterApplications < ActiveRecord::Migration[8.1]
  def change
    create_table :visa_letter_applications, id: :uuid do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true, index: false
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.references :participant_event, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.references :invitation, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.references :visa_letter_invitation, type: :uuid, foreign_key: { on_delete: :nullify }, index: true

      t.string :full_name, null: false
      t.string :email, null: false
      t.date :date_of_birth, null: false
      t.string :nationality, null: false
      t.string :place_of_birth
      t.string :phone
      t.text :address

      t.string :status, null: false, default: "pending"
      t.string :rejection_type
      t.text :rejection_reason
      t.text :admin_notes
      t.references :reviewed_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.datetime :reviewed_at
      t.datetime :submitted_at

      t.string :reference_number, null: false
      t.string :verification_code, null: false
      t.string :letter_event_name
      t.string :letter_venue
      t.string :letter_address
      t.string :letter_city
      t.string :letter_country
      t.date :letter_starts_on
      t.date :letter_ends_on
      t.date :letter_issued_on
      t.datetime :letter_sent_at

      t.string :visa_outcome, null: false, default: "unknown"
      t.datetime :visa_outcome_recorded_at
      t.datetime :imported_at

      t.timestamps
    end

    add_index :visa_letter_applications, [ :event_id, :status ]
    add_index :visa_letter_applications, [ :event_id, :user_id ], unique: true, where: "user_id IS NOT NULL"
    add_index :visa_letter_applications, :email
    add_index :visa_letter_applications, :reference_number, unique: true
    add_index :visa_letter_applications, :verification_code, unique: true
  end
end
