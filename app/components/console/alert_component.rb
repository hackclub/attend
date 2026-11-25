module Console
  # Cloudscape's alert: 2px status-colour border, tinted background, the
  # status icon, then a body with an optional bold title. Behind `cs_alert`
  # and, for form-level errors, `cs_form_alert`.
  #
  #   <%= cs_alert :warning, title: "Onboarding invitations are held for this event." do %>
  #     <p>The participant will be added to the pending list without an email.</p>
  #   <% end %>
  class AlertComponent < ApplicationComponent
    TYPES = %i[info warning error success].freeze

    def initialize(type = :info, title: nil, tag: :div, class: nil, **attributes)
      @type = type.to_sym
      raise ArgumentError, "unknown cs-alert type: #{type.inspect}" if TYPES.exclude?(@type)

      @title = title
      @tag = tag
      # A plain cs-alert is the info alert; there is no cs-alert-info class.
      @classes = class_list("cs-alert", ("cs-alert-#{@type}" unless @type == :info), binding.local_variable_get(:class))
      @attributes = attributes
    end

    def call
      content_tag(@tag, class: @classes, **@attributes) do
        render(StatusIconComponent.new(@type)) + content_tag(:div, safe_join([
          (content_tag(:p, @title, class: "cs-alert-title") if @title),
          content
        ].compact))
      end
    end
  end
end
