module Console
  # Cloudscape's status indicator: an icon plus a coloured word. The word
  # always carries the meaning; the colour and icon only reinforce it.
  # Behind `cs_status(type, label)`. Unknown types fall back to info.
  class StatusComponent < ApplicationComponent
    def initialize(type, label)
      type = type.to_s.to_sym
      @type = StatusIconComponent::ICONS.key?(type) ? type : :info
      @label = label
    end

    def call
      content_tag(:span, class: "cs-status cs-status-#{@type.to_s.dasherize}") do
        render(StatusIconComponent.new(@type)) + content_tag(:span, @label)
      end
    end
  end
end
