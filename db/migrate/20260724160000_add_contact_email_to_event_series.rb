class AddContactEmailToEventSeries < ActiveRecord::Migration[8.1]
  def change
    add_column :event_series, :contact_email, :string
  end
end
