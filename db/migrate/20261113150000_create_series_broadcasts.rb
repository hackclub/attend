# One message to participants across many events in a series. Sending it
# creates an ordinary Message per event (messages.series_broadcast_id), so
# deliveries, inboxes and the per-event messages page work as they do for any
# other message.
#
# A series broadcast is screened once, at the series level, so its held
# review names the series rather than one event: broadcast_reviews.event_id
# becomes optional, with event_series_id alongside it.
class CreateSeriesBroadcasts < ActiveRecord::Migration[8.1]
  def change
    create_table :series_broadcasts, id: :uuid do |t|
      t.references :event_series, type: :uuid, null: false, foreign_key: true
      t.references :sent_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :subject
      t.text :body, null: false, default: ""
      t.string :channels, array: true, null: false, default: []
      t.string :audience, null: false
      t.jsonb :audience_filters, null: false, default: {}
      t.string :event_scope, null: false, default: "upcoming"
      t.uuid :selected_event_ids, array: true, null: false, default: []
      t.uuid :skipped_event_ids, array: true, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.string :screened_digest
      t.datetime :scheduled_at
      t.datetime :sent_at
      t.datetime :fanned_out_at
      t.timestamps
    end
    add_index :series_broadcasts, [ :status, :scheduled_at ]

    add_reference :messages, :series_broadcast, type: :uuid, foreign_key: true, index: false
    # One child per event, which is what makes the fan-out safe to re-run.
    add_index :messages, [ :series_broadcast_id, :event_id ], unique: true, where: "series_broadcast_id IS NOT NULL"

    change_column_null :broadcast_reviews, :event_id, true
    add_reference :broadcast_reviews, :event_series, type: :uuid, foreign_key: true
  end
end
