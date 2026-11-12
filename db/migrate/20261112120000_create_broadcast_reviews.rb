class CreateBroadcastReviews < ActiveRecord::Migration[8.1]
  def change
    # One row per broadcast the screener held back. An admin approves (the
    # broadcast goes out) or rejects (it goes back to its author) it.
    create_table :broadcast_reviews, id: :uuid do |t|
      t.references :reviewable, polymorphic: true, type: :uuid, null: false
      t.references :event, type: :uuid, null: false, foreign_key: true
      t.references :submitted_by_user, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :status, null: false, default: "pending"
      t.string :flagged_by, null: false
      t.string :categories, array: true, null: false, default: []
      t.text :reason
      t.string :content_digest, null: false
      t.references :decided_by_user, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :decided_at
      t.text :decision_note
      t.timestamps
    end
    add_index :broadcast_reviews, [ :status, :created_at ]

    # Digest of the content the screener (or an admin) last cleared, so a
    # broadcast isn't screened twice and an approval survives until someone
    # edits what was approved.
    add_column :messages, :screened_digest, :string
    add_column :slack_blasts, :screened_digest, :string
  end
end
