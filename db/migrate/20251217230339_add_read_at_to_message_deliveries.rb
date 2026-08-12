class AddReadAtToMessageDeliveries < ActiveRecord::Migration[8.1]
  def change
    add_column :message_deliveries, :read_at, :datetime
  end
end
