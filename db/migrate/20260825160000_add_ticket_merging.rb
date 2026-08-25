class AddTicketMerging < ActiveRecord::Migration[8.1]
  def change
    add_reference :tickets, :merged_into, foreign_key: { to_table: :tickets }, type: :uuid
    add_reference :tickets, :merged_by, foreign_key: { to_table: :users }, type: :uuid
    add_column :tickets, :merged_at, :datetime

    add_reference :ticket_messages, :merged_from_ticket, foreign_key: { to_table: :tickets }, type: :uuid
  end
end
