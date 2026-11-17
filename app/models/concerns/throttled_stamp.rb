# A timestamp that records "this was used", stamped from the request that
# used it, at most once per interval.
#
# These columns answer questions measured in hours or days (is this key still
# in use? is this invite still live?), so a stamp already inside the interval
# is left alone. Stamping every request would make each of them a write.
#
# update_column: no validations, callbacks or PaperTrail version for what is
# only bookkeeping.
module ThrottledStamp
  extend ActiveSupport::Concern

  def stamp_at_most_every(interval, column)
    stamped_at = self[column]
    return if stamped_at.present? && stamped_at > interval.ago

    # Explicitly on the primary: a request serving reads from the replica
    # (ReplicaReads) may still reach this.
    ReplicaReads.on_primary { update_column(column, Time.current) }
  end
end
