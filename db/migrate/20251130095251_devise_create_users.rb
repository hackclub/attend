# frozen_string_literal: true

class DeviseCreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users, id: :uuid, default: "gen_random_uuid()" do |t|
      t.string :email, null: false
      t.string :name
      t.string :hack_club_account_id
      t.string :global_role, default: "none"
      t.string :time_zone, default: "UTC"

      ## Database authenticatable
      t.string :encrypted_password, null: false, default: ""

      ## Recoverable
      t.string   :reset_password_token
      t.datetime :reset_password_sent_at

      ## Rememberable
      t.datetime :remember_created_at

      ## Trackable
      t.integer  :sign_in_count, default: 0, null: false
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string   :current_sign_in_ip
      t.string   :last_sign_in_ip

      t.timestamps null: false
    end

    add_index :users, :email, unique: true
    add_index :users, :hack_club_account_id, unique: true
    add_index :users, :global_role
    add_index :users, :reset_password_token, unique: true
  end
end
