class AddTicketIdToNotes < ActiveRecord::Migration[8.1]
  def change
    add_reference :notes, :ticket, type: :uuid, foreign_key: true, null: true
    change_column_null :notes, :event_id, true
  end
end
