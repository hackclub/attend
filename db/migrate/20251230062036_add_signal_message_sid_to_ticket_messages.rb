class AddSignalMessageSidToTicketMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :ticket_messages, :signal_message_sid, :string
    add_index :ticket_messages, :signal_message_sid, unique: true, where: "signal_message_sid IS NOT NULL"
  end
end
