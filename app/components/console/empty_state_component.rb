module Console
  # Cloudscape's empty state: centred, muted, a bold title, optional text and
  # centred actions. Behind `cs_empty` and `cs_no_match`.
  #
  #   <%= cs_empty "No scan contexts", "No scan contexts configured for this event." do |empty| %>
  #     <% empty.with_actions do %><%= cs_button "New context", href: new_path %><% end %>
  #   <% end %>
  class EmptyStateComponent < ApplicationComponent
    renders_one :actions

    def initialize(title, description = nil, class: nil, **attributes)
      @title = title
      @description = description
      @classes = class_list("cs-empty", binding.local_variable_get(:class))
      @attributes = attributes
    end

    def call
      # Rendering content first lets a block register the actions slot.
      extra = content
      content_tag(:div, class: @classes, **@attributes) do
        safe_join([
          content_tag(:p, @title, class: "cs-empty-title"),
          (content_tag(:p, @description) if @description),
          extra.presence,
          (content_tag(:div, actions, class: "cs-actions") if actions?)
        ].compact)
      end
    end
  end
end
