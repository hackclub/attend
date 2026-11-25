# Helper API for the portal kit: the `portal-*` classes in
# app/assets/tailwind/application.css that dress participant, guardian,
# training and the other Clipboard surfaces. The markup lives in the
# components under app/components/portal; these are thin delegates, the same
# arrangement as the console's cs_* helpers.
module PortalHelper
  # A portal button. `variant` is nil (the bare base), :primary, :secondary
  # or :quiet. It submits by default; `href:` makes it a link that looks like
  # a button. Pass a block for content that isn't a plain label.
  #   <%= portal_button "Verify", variant: :primary, class: "w-full sm:w-auto mt-4" %>
  #   <%= portal_button "Find my portals", variant: :primary, href: guardian_portal_center_path %>
  def portal_button(label = nil, **options, &block)
    component = Portal::ButtonComponent.new(label, **options)
    component.with_content(capture(&block)) if block
    render component
  end

  # The class string for builders that emit their own element:
  #   <%= button_to "Stop texts", path, class: portal_button_classes(:primary, "w-full sm:w-auto") %>
  def portal_button_classes(variant = nil, extra = nil)
    Portal::ButtonComponent.classes(variant, extra)
  end

  # A portal card. Padding and spacing are the caller's utilities.
  #   <%= portal_card class: "p-5 sm:p-6 mb-6" do %>…<% end %>
  def portal_card(**options, &block)
    render Portal::CardComponent.new(**options).with_content(capture(&block))
  end

  # The quieter sunken panel, for asides and explanations.
  #   <%= portal_panel class: "p-5" do %>…<% end %>
  def portal_panel(**options, &block)
    portal_card(panel: true, **options, &block)
  end

  # A portal form field: label, optional hint, then the block's control.
  #   <%= portal_field "Full Name", for: ec.field_id(:name), required: true do %>
  #     <%= ec.text_field :name, class: "portal-input", required: true %>
  #   <% end %>
  def portal_field(label, **options, &block)
    render Portal::FieldComponent.new(label, **options).with_content(capture(&block))
  end
end
