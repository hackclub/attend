# last_used_at for API credentials, stamped from the request that used them.
#
# It answers "is this key still in use?", which needs nothing finer than a
# quarter of an hour, so a credential already stamped inside that window is
# left alone. Stamping every request made each API GET a write (and a row
# update per call for a polling client).
module LastUsedTracking
  extend ActiveSupport::Concern

  LAST_USED_TOUCH_INTERVAL = 15.minutes

  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_TOUCH_INTERVAL.ago

    update_column(:last_used_at, Time.current)
  end
end
