class CreateGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :groups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :event, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.string :color
      t.text :description
      t.integer :position, default: 0, null: false
      t.timestamps
    end

    add_index :groups, [ :event_id, :slug ], unique: true
    add_index :groups, [ :event_id, :name ], unique: true
    add_index :groups, [ :event_id, :position ]
  end
end
