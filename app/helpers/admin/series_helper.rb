module Admin::SeriesHelper
  # Sequential ramp for "share of this event's participants still blocked".
  # One hue, light to deep, so it reads as a magnitude rather than a traffic
  # light: pale means nothing to see here, deep means go here first. Fixed hex
  # rather than theme tokens because these sit on OpenStreetMap tiles, which are
  # light under every app theme.
  #
  # Every step clears 3:1 (WCAG 1.4.11) against both a mid-tone OSM tile
  # (#e8e0d8) and the marker's own 2px white ring, so the lightest step is a
  # mid rose rather than the pale pink this ramp used to open on: 3.34, 4.86,
  # 6.42, 8.43, 10.80 against the tile. The ratios climb ~1.3x a step, which is
  # what keeps the sequence legible as a magnitude once it is dark enough to
  # see at all.
  BLOCKED_RAMP = [
    [ 0.00, "#cf4a63" ],
    [ 0.10, "#ab3252" ],
    [ 0.25, "#8f2444" ],
    [ 0.45, "#731833" ],
    [ 0.65, "#560f24" ]
  ].freeze

  def series_blocked_fill(share)
    BLOCKED_RAMP.reverse.find { |threshold, _| share >= threshold }&.last || BLOCKED_RAMP.first.last
  end

  # Marker geometry and colour are computed here so the Stimulus controller stays
  # a renderer: it places what it is given and owns no thresholds.
  def series_map_markers(rows)
    rows.filter_map do |row|
      event = row[:event]
      coordinates = event.venue_coordinates
      next if coordinates.nil?

      blocked = row[:active] - row[:cleared]
      share = row[:active].positive? ? blocked.to_f / row[:active] : 0.0

      {
        id: event.id,
        lat: coordinates[:lat],
        lon: coordinates[:lon],
        name: event.name,
        location: [ event.location_city, event.location_country ].compact_blank.join(", "),
        dates: event_date_range(event.starts_at, event.ends_at),
        url: admin_event_dashboard_path(event.slug),
        active: row[:active],
        blocked: blocked,
        percent: row[:percent],
        fill: series_blocked_fill(share),
        # Area carries the count, so the radius is a bare sqrt with no additive
        # base — an offset would flatten the scale and make a 40-person event
        # look barely bigger than a 12-person one. The floor only lifts events
        # too small to be clickable otherwise.
        radius: (Math.sqrt(row[:active]) * 3.6).clamp(10, 34).round
      }
    end
  end

  # The participant list for one event, filtered to the people stuck at a stage.
  # Passing the event slug in the path is what switches the admin event picker
  # (Admin::BaseController#switch_event_if_needed), so these links land on a
  # populated list rather than the "select an event first" redirect.
  def series_chase_path(event, stage)
    admin_event_participants_path(event.slug, stage.filter || {})
  end

  # ── Funnel ribbon ────────────────────────────────────────────────────────
  #
  # A single tapering Sankey-style ribbon: the band's height at any point is the
  # share of participants still moving, so the loss at a stage is the visible
  # narrowing rather than a separate mark. One flat fill, not the gradient the
  # form usually ships with — DESIGN.md keeps gradients out of the app shell.
  #
  # Geometry only. Percentages come from SeriesDashboard so the ribbon and the
  # chase list cannot drift apart.
  FUNNEL_VIEW_WIDTH = 1000
  FUNNEL_VIEW_HEIGHT = 180

  def series_funnel_ribbon(stage_rows)
    return nil if stage_rows.empty?

    segments = stage_rows.length
    step = FUNNEL_VIEW_WIDTH.to_f / segments
    centre = FUNNEL_VIEW_HEIGHT / 2.0

    # One more node than there are stages: the left edge is the whole active
    # population, before anyone has been filtered out.
    halves = ([ 100.0 ] + stage_rows.map { |row| row[:percent].to_f })
      .map { |percent| percent / 100.0 * centre }

    { path: funnel_ribbon_path(segments, step, centre, halves), segments: segments }
  end

  private

  def funnel_ribbon_path(segments, step, centre, halves)
    d = +"M 0 #{fnum(centre - halves[0])}"

    # Top edge, left to right. Both control points sit on the segment's midpoint
    # x, which is what gives each drop the eased S the reference has.
    segments.times do |i|
      mid = (i + 0.5) * step
      d << " C #{fnum(mid)} #{fnum(centre - halves[i])},"            " #{fnum(mid)} #{fnum(centre - halves[i + 1])},"            " #{fnum((i + 1) * step)} #{fnum(centre - halves[i + 1])}"
    end

    d << " L #{FUNNEL_VIEW_WIDTH} #{fnum(centre + halves[segments])}"

    # Bottom edge, mirrored, right to left.
    (segments - 1).downto(0) do |i|
      mid = (i + 0.5) * step
      d << " C #{fnum(mid)} #{fnum(centre + halves[i + 1])},"            " #{fnum(mid)} #{fnum(centre + halves[i])},"            " #{fnum(i * step)} #{fnum(centre + halves[i])}"
    end

    d << " Z"
  end

  def fnum(value)
    format("%.2f", value).sub(/\.?0+\z/, "")
  end
end
