# People who asked us to stop texting them, by replying STOP or through the
# opt-out link in a text. Unlike SmsSuppression this never expires: only the
# person turning texts back on (START, or the link page) removes it.
class CreateSmsOptOuts < ActiveRecord::Migration[8.1]
  def change
    create_table :sms_opt_outs, id: :uuid do |t|
      t.string :phone_number, null: false
      t.string :source, null: false
      t.datetime :opted_out_at, null: false
      t.timestamps
    end
    add_index :sms_opt_outs, :phone_number, unique: true
  end
end
