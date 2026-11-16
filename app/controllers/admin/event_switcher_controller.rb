module Admin
  # The event switcher's list (layouts/_admin_event_switcher_items), fetched
  # into the switcher menu the first time it opens rather than rendered into
  # every admin page.
  class EventSwitcherController < BaseController
    global_page

    FRAMES = %w[event_switcher_items_topnav event_switcher_items_drawer].freeze

    def show
      @frame_id = FRAMES.include?(request.headers["Turbo-Frame"]) ? request.headers["Turbo-Frame"] : FRAMES.first
      render layout: false
    end
  end
end
