module Console
  # A 4px-radius chip for labels and counts. Behind `cs_badge(label, color)`
  # and `cs_severity_badge(severity, label)`. Prefer a status indicator for
  # any lifecycle state.
  class BadgeComponent < ApplicationComponent
    SEVERITIES = %w[critical high medium low neutral].freeze

    # The incident severity ramp. Unknown severities render as neutral, with
    # the severity's own name as the label unless one is given.
    def self.severity(severity, label = nil)
      level = SEVERITIES.include?(severity.to_s) ? severity.to_s : "neutral"
      new(label || severity.to_s.humanize, "severity-#{level}")
    end

    def initialize(label, color = nil)
      @label = label
      @color = color
    end

    def call
      content_tag(:span, @label, class: class_list("cs-badge", ("cs-badge-#{@color}" if @color)))
    end
  end
end
