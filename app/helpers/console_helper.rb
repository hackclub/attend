# Helpers for the admin console, the Cloudscape-based /admin shell. Styles
# live in app/assets/stylesheets/console.css.
module ConsoleHelper
  # The console has Cloudscape's two modes rather than the nine app themes.
  # Light-ground themes land on light, everything else on dark.
  LIGHT_THEMES = %w[light catppuccin-latte].freeze

  CONSOLE_THEME_COLOR = "#0f141a".freeze

  STATUS_ICONS = {
    success: '<circle cx="8" cy="8" r="7"/><path d="M4.5 8.2l2.3 2.3 4.7-4.9"/>',
    error: '<circle cx="8" cy="8" r="7"/><path d="M5.5 5.5l5 5m0-5l-5 5"/>',
    warning: '<path d="M8 1.5l7 12.5H1z"/><path d="M8 6v4m0 1.8v.2"/>',
    info: '<circle cx="8" cy="8" r="7"/><path d="M8 7v4.5m0-6.8v.3"/>',
    pending: '<circle cx="8" cy="8" r="7"/><path d="M8 4.5V8l2.5 1.8"/>',
    in_progress: '<circle cx="8" cy="8" r="7" stroke-dasharray="3 2.5"/><circle cx="8" cy="8" r="1.4" fill="currentColor" stroke="none"/>',
    stopped: '<circle cx="8" cy="8" r="7"/><path d="M5 8h6"/>'
  }.freeze

  # True when this request renders the +console template variant. Helpers
  # shared by both admin UIs branch on it, so the original templates keep
  # their Tailwind markup and the console gets cs-* markup.
  def console_ui?
    respond_to?(:request) && request.present? && Array(request.variant).include?(:console)
  end

  SYSTEM_THEME = "system".freeze

  # The console's theme setting: "light", "dark" or "system". Any of the
  # nine app themes collapses to light or dark; "system" follows the OS.
  def admin_console_theme_mode
    raw = (current_user.respond_to?(:theme) && current_user&.theme.presence) || cookies[:attend_theme].presence
    return SYSTEM_THEME if raw == SYSTEM_THEME

    LIGHT_THEMES.include?(current_theme) ? "light" : "dark"
  end

  # What the server renders into data-theme. "system" can only be resolved
  # in the browser, so it renders light and the layout's pre-paint script
  # switches to dark when the OS asks for it.
  def admin_console_theme
    mode = admin_console_theme_mode
    mode == SYSTEM_THEME ? "light" : mode
  end

  # Cloudscape's status indicator: an icon plus a coloured word. The word
  # always carries the meaning; the colour and icon only reinforce it.
  def cs_status(type, label)
    type = type.to_s.to_sym
    type = :info unless STATUS_ICONS.key?(type)
    content_tag(:span, class: "cs-status cs-status-#{type.to_s.dasherize}") do
      cs_status_icon(type) + content_tag(:span, label)
    end
  end

  def cs_status_icon(type)
    content_tag(:svg, STATUS_ICONS.fetch(type.to_sym).html_safe,
      viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
      "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round",
      "aria-hidden": "true")
  end

  def cs_badge(label, color = nil)
    classes = [ "cs-badge" ]
    classes << "cs-badge-#{color}" if color
    content_tag(:span, label, class: classes.join(" "))
  end

  # Cloudscape's breadcrumb group. Pass [label, path] pairs; the last one is
  # the current page and renders as text.
  #   content_for :breadcrumbs, cs_breadcrumbs([ "Events", admin_root_path ], [ @event.name, nil ])
  def cs_breadcrumbs(*crumbs)
    content_tag(:nav, "aria-label": "Breadcrumbs") do
      content_tag(:ol, class: "cs-breadcrumb-group") do
        safe_join(crumbs.each_with_index.map do |(label, path), index|
          last = index == crumbs.size - 1
          content_tag(:li) do
            if last || path.nil?
              content_tag(:span, label, "aria-current": ("page" if last))
            else
              link_to(label, path)
            end
          end
        end)
      end
    end
  end

  # The trail for any page under an event: Events › {event} › *crumbs.
  # `event_name` lets a form page keep the saved name while an edit is invalid.
  #   content_for :breadcrumbs, cs_event_breadcrumbs([ "Incidents", admin_event_incidents_path(current_event) ], [ "New incident", nil ])
  def cs_event_breadcrumbs(*crumbs, event: current_event, event_name: event.name, event_slug: event.slug)
    cs_breadcrumbs([ "Events", admin_root_path ], [ event_name, admin_event_dashboard_path(event_slug) ], *crumbs)
  end

  # A crumb whose target is policy-gated: links only when the viewer passes
  # the gate, otherwise it renders as plain text so it never dead-ends.
  def cs_gated_crumb(label, path, allowed)
    [ label, (path if allowed) ]
  end

  # Cloudscape severity badge for incidents and other graded things.
  SEVERITY_BADGES = %w[critical high medium low neutral].freeze

  def cs_severity_badge(severity, label = nil)
    level = SEVERITY_BADGES.include?(severity.to_s) ? severity.to_s : "neutral"
    content_tag(:span, label || severity.to_s.humanize, class: "cs-badge cs-badge-severity-#{level}")
  end

  # aria-current for side navigation links, so the active state is exposed
  # to assistive tech rather than drawn in colour alone.
  def cs_current(active)
    active ? "page" : nil
  end
end
