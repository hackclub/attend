# The first, additive slice of a unified identity model: a person sitting
# above the users, participants and guardians rows that describe the same
# human, with the addresses and numbers they are reachable on.
#
# Nothing reads these yet. The existing email/phone columns stay the source of
# truth, and `identity:backfill` fills the new tables in.
class CreateIdentityTables < ActiveRecord::Migration[8.1]
  def change
    create_table :people, id: :uuid do |t|
      t.timestamps
    end

    create_table :email_addresses, id: :uuid do |t|
      t.references :person, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      # Always stripped and downcased (see EmailAddress.normalize).
      t.string :address, null: false
      t.datetime :verified_at
      t.boolean :primary, null: false, default: false
      t.string :source, null: false
      t.timestamps
    end
    add_index :email_addresses, [ :person_id, :address ], unique: true
    add_index :email_addresses, :address
    # An address can be proven by one person only. Unverified rows may repeat:
    # a parent's inbox typed onto each of their children's registrations.
    add_index :email_addresses, :address, unique: true, where: "verified_at IS NOT NULL",
      name: "index_email_addresses_on_verified_address"
    add_index :email_addresses, :person_id, unique: true, where: '"primary"',
      name: "index_email_addresses_on_primary_per_person"

    create_table :phone_numbers, id: :uuid do |t|
      t.references :person, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      # E.164, deterministically encrypted like participants.phone. Deliberately
      # not unique across people: a number never identifies anyone.
      t.text :number, null: false
      t.datetime :verified_at
      t.string :source, null: false
      t.timestamps
    end
    add_index :phone_numbers, [ :person_id, :number ], unique: true
    add_index :phone_numbers, :number

    # Rows the backfill refused to join up on its own. Holds record ids only,
    # never an address or a name; `fingerprint` is a digest that keeps a re-run
    # from recording the same group twice.
    create_table :identity_reviews, id: :uuid do |t|
      t.string :category, null: false
      t.string :reasons, array: true, null: false, default: []
      t.uuid :user_ids, array: true, null: false, default: []
      t.uuid :participant_ids, array: true, null: false, default: []
      t.uuid :guardian_ids, array: true, null: false, default: []
      t.string :fingerprint, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :identity_reviews, :fingerprint, unique: true
    add_index :identity_reviews, :category

    add_reference :users, :person, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
    add_reference :participants, :person, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
    add_reference :guardians, :person, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
  end
end
