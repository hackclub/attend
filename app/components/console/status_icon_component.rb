module Console
  # The 16px stroked icon shared by status indicators, alerts and field
  # messages. Behind `cs_status_icon`.
  class StatusIconComponent < ApplicationComponent
    ICONS = {
      success: '<circle cx="8" cy="8" r="7"/><path d="M4.5 8.2l2.3 2.3 4.7-4.9"/>',
      error: '<circle cx="8" cy="8" r="7"/><path d="M5.5 5.5l5 5m0-5l-5 5"/>',
      warning: '<path d="M8 1.5l7 12.5H1z"/><path d="M8 6v4m0 1.8v.2"/>',
      info: '<circle cx="8" cy="8" r="7"/><path d="M8 7v4.5m0-6.8v.3"/>',
      pending: '<circle cx="8" cy="8" r="7"/><path d="M8 4.5V8l2.5 1.8"/>',
      in_progress: '<circle cx="8" cy="8" r="7" stroke-dasharray="3 2.5"/><circle cx="8" cy="8" r="1.4" fill="currentColor" stroke="none"/>',
      stopped: '<circle cx="8" cy="8" r="7"/><path d="M5 8h6"/>'
    }.freeze

    def initialize(type)
      @type = type.to_sym
    end

    def call
      content_tag(:svg, ICONS.fetch(@type).html_safe,
        viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
        "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round",
        "aria-hidden": "true")
    end
  end
end
