# Who can message a whole series at once.
#
# Series owners and global admins (User#series_owner_for? covers both).
# Reaching every event in a series at once is a series-wide act, like
# releasing held invitations, so it is the owners' call. Organizers and event
# staff message their own events from each event's messages page; their
# copies of a series broadcast show up there too.
class SeriesBroadcastPolicy < ApplicationPolicy
  def index?
    manage?
  end

  def show?
    manage?
  end

  def create?
    manage?
  end

  def update?
    manage?
  end

  def destroy?
    manage?
  end

  def preview?
    manage?
  end

  def send_now?
    manage?
  end

  def cancel?
    manage?
  end

  private

  def manage?
    series = record.is_a?(EventSeries) ? record : record.event_series
    series.present? && user.series_owner_for?(series)
  end
end
