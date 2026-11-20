module Portal
  # The portal kit's surfaces: a card (white, hairline border, 8px radius) or,
  # with `panel: true`, the quieter sunken panel used for asides. Padding and
  # spacing stay with the caller as utilities, as the kit has always had it.
  # Behind `portal_card` and `portal_panel`.
  #
  #   <%= portal_card class: "p-5 sm:p-6 mb-6" do %>…<% end %>
  #   <%= portal_card tag: :section, class: "p-5 sm:p-6" do %>…<% end %>
  class CardComponent < ApplicationComponent
    def initialize(tag: :div, panel: false, class: nil, **attributes)
      @tag = tag
      @classes = class_list(panel ? "portal-panel" : "portal-card", binding.local_variable_get(:class))
      @attributes = attributes
    end

    def call
      content_tag(@tag, content, class: @classes, **@attributes)
    end
  end
end
