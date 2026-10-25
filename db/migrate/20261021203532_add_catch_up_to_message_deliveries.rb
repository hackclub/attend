class AddCatchUpToMessageDeliveries < ActiveRecord::Migration[8.1]
  def change
    # True for deliveries created by Message#send_to_new_recipients! rather
    # than the original send.
    add_column :message_deliveries, :catch_up, :boolean, null: false, default: false
  end
end
