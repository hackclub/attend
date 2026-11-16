# Renders a section of a page after the page itself.
#
#   <%= lazy_frame "series_dashboard", src: dashboard_admin_series_path(@series) do %>
#     <%= render "shared/skeleton", shape: :panel %>
#   <% end %>
#
# The page answers straight away with the block (a skeleton) in the section's
# place; the browser then fetches `src`, whose response renders the real
# section inside a frame with the same id (see #lazy_frame_response). Use it
# for the slow part of a page — a dashboard's tallies, a count across every
# user — so the rest of the page, and the admin chrome, stop waiting on it.
#
# Turbo swaps only the frame's children into the page and keeps the page's
# own <turbo-frame>, so a layout class (cs-stack, space-y-*) must go on
# #lazy_frame here. On #lazy_frame_response alone it is silently dropped.
#
# Links and forms inside the section act on the whole page (target "_top"),
# as they did before it was split out. Pass `loading: :lazy` for a section
# below the fold to wait until it's scrolled to.
module LazyFrameHelper
  def lazy_frame(id, src:, loading: :eager, retry_class: nil, **options, &block)
    options[:class] = class_names("lazy-frame", options[:class])
    options[:data] = { lazy_frame_retry_class: retry_class || lazy_frame_retry_class }.merge(options[:data] || {})

    turbo_frame_tag(id, src: src, loading: loading, target: "_top", **options) do
      if block
        capture(&block)
      else
        render("shared/skeleton")
      end
    end
  end

  # Wraps the section's real content for the frame request to swap in.
  def lazy_frame_response(id, **options, &block)
    options[:class] = class_names("lazy-frame", options[:class])
    turbo_frame_tag(id, target: "_top", **options, &block)
  end

  private

  def lazy_frame_retry_class
    respond_to?(:console_ui?) && console_ui? ? "cs-link" : "underline"
  end
end
