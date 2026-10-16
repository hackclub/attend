# Helpers for the Haven onboarding skin (EventSeries#haven_onboarding?).
module HavenHelper
  HAVEN_TSHIRT_IMAGE = "haven/tshirt.webp"

  # Luma page for Haven's online workshop series, promoted on the
  # "you're registered" screen. The card stays hidden while this is nil.
  HAVEN_WORKSHOPS_URL = nil

  # The shirt art isn't final yet; the image slot stays hidden until
  # app/assets/images/haven/tshirt.webp exists.
  def haven_tshirt_image?
    Rails.application.assets.load_path.find(HAVEN_TSHIRT_IMAGE).present?
  end

  # "Downtown Library, Boston" — venue and city, whichever are set.
  def haven_event_location(event)
    [ event.venue_name, event.location_city ].filter_map(&:presence).uniq.join(", ")
  end
end
