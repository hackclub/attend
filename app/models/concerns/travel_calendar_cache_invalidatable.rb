module TravelCalendarCacheInvalidatable
  extend ActiveSupport::Concern

  included do
    before_destroy :remember_travel_calendar_event_ids, unless: :travel_calendar_destroyed_by_association?
    after_commit :invalidate_travel_calendar_cache, unless: :travel_calendar_destroyed_by_association?
  end

  private

  def remember_travel_calendar_event_ids
    @travel_calendar_event_ids_before_destroy = travel_calendar_event_ids
  end

  def travel_calendar_destroyed_by_association?
    destroyed_by_association.present?
  end

  def invalidate_travel_calendar_cache
    event_ids = destroyed? ? @travel_calendar_event_ids_before_destroy : travel_calendar_event_ids
    TravelCalendar::JourneyCache.clear_event_ids(event_ids)
  ensure
    @travel_calendar_event_ids_before_destroy = nil
  end
end
