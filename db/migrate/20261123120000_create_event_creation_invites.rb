# A global admin's invitation for someone to create an event themselves and
# run its setup. One invite makes one event: `completed_at` marks it used, and
# is kept apart from `event_id` so deleting the event doesn't hand the invite
# back.
class CreateEventCreationInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :event_creation_invites, id: :uuid do |t|
      t.string :email, null: false
      # SHA-256 of the link's token. The token itself only ever exists in the
      # email, so nothing here (or in the audit log) can be used to open it.
      t.string :token_digest
      t.text :note
      t.references :invited_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :accepted_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :event_series, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :event, type: :uuid, foreign_key: { on_delete: :nullify }
      t.datetime :expires_at, null: false
      t.datetime :last_sent_at
      t.datetime :accepted_at
      t.datetime :completed_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :event_creation_invites, :token_digest, unique: true
    add_index :event_creation_invites, :email
  end
end
