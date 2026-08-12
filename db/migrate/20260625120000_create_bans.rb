class CreateBans < ActiveRecord::Migration[8.1]
  def change
    create_table :bans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.text :reason
      t.datetime :expires_at
      t.references :created_by, type: :uuid, null: true, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :bans, :expires_at
  end
end
