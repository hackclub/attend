# Numbers that SMS can't reach for a reason that won't fix itself before the
# next send: the carrier rejects our sender, the country is switched off,
# the person replied STOP, or the number isn't a mobile. Without this we kept
# texting the same dead numbers on every broadcast, which is what dragged the
# Twilio health score down.
class CreateSmsSuppressions < ActiveRecord::Migration[8.1]
  def change
    create_table :sms_suppressions, id: :uuid do |t|
      t.string :phone_number, null: false
      t.string :error_code, null: false
      t.datetime :failed_at, null: false
      t.timestamps
    end
    add_index :sms_suppressions, :phone_number, unique: true
  end
end
