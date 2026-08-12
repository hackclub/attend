class CreatePushTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :push_tokens, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.string :token, null: false
      t.string :platform

      t.timestamps
    end
    add_index :push_tokens, :token, unique: true
    add_index :push_tokens, [ :user_id, :event_id, :token ], unique: true
  end
end
