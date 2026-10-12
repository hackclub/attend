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

  def admin_console_theme
    LIGHT_THEMES.include?(current_theme) ? "light" : "dark"
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
