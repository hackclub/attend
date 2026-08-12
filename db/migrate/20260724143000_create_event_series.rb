class CreateEventSeries < ActiveRecord::Migration[8.1]
  def change
    create_table :event_series, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description

      t.timestamps

      t.index :slug, unique: true
    end

    create_table :series_role_assignments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false
      t.uuid :event_series_id, null: false
      t.string :role, null: false

      t.timestamps

      t.index [ :user_id, :event_series_id ], unique: true
      t.index :event_series_id
      t.index :user_id
    end

    add_foreign_key :series_role_assignments, :users
    add_foreign_key :series_role_assignments, :event_series

    add_column :events, :event_series_id, :uuid
    add_index :events, :event_series_id
    add_foreign_key :events, :event_series
  end
end
