class AddAutomatedToTicketMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :ticket_messages, :automated, :boolean, default: false, null: false
  end
end
