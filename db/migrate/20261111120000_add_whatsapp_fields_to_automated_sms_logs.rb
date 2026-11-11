class AddWhatsappFieldsToAutomatedSmsLogs < ActiveRecord::Migration[8.1]
  def change
    change_table :automated_sms_logs, bulk: true do |t|
      t.string :channel, null: false, default: "sms"
      t.string :content_sid
      t.text :sms_fallback_body
      t.references :message_delivery, type: :uuid, foreign_key: { on_delete: :nullify }, index: true
      t.string :error_code
      t.datetime :fell_back_at
    end
  end
end
