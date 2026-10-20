class AddConfigToEventSeries < ActiveRecord::Migration[8.1]
  def change
    add_column :event_series, :config, :jsonb, default: {}, null: false
  end
end
