# The scanner now queues scans on the device when the venue network drops and
# replays them later. `scanned_at` stays the time the server stands behind;
# this keeps the device's own claim beside it, so a clock that was wrong (or a
# scan that sat in a queue) can be told apart from one recorded live.
#
# The idempotency key those replays rely on is `client_scan_id`, which already
# has a unique index (index_scans_on_client_scan_id).
class AddClientScannedAtToScans < ActiveRecord::Migration[8.1]
  def change
    add_column :scans, :client_scanned_at, :datetime
  end
end
