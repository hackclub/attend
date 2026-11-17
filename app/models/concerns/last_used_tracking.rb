# last_used_at for API credentials, stamped from the request that used them.
#
# It answers "is this key still in use?", which needs nothing finer than a
# quarter of an hour, so a credential already stamped inside that window is
# left alone. Stamping every request made each API GET a write (and a row
# update per call for a polling client).
module LastUsedTracking
  extend ActiveSupport::Concern
  include ThrottledStamp

  LAST_USED_TOUCH_INTERVAL = 15.minutes

  def touch_last_used!
    stamp_at_most_every(LAST_USED_TOUCH_INTERVAL, :last_used_at)
  end
end
