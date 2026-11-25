module Portal
  # The portal kit's button (participant, guardian, training and other
  # Clipboard surfaces): primary (deepened red fill), secondary (bordered),
  # quiet (text-only) or the bare base. With `href:` it renders a link that
  # looks like a button; otherwise a <button>, type="submit" by default since
  # nearly every portal button submits its form. Behind `portal_button`.
  #
  #   <%= portal_button "Verify", variant: :primary, class: "w-full sm:w-auto mt-4" %>
  #   <%= portal_button "Find my portals", variant: :primary, href: guardian_portal_center_path %>
  #
  # For builders that emit their own element (`button_to`, `f.submit`), take
  # the class string from `portal_button_classes(:primary, "w-full sm:w-auto")`.
  class ButtonComponent < ApplicationComponent
    VARIANTS = %i[primary secondary quiet].freeze

    def self.classes(variant = nil, extra = nil)
      variant = variant&.to_sym
      raise ArgumentError, "unknown portal-btn variant: #{variant.inspect}" if variant && VARIANTS.exclude?(variant)

      [ "portal-btn", ("portal-btn-#{variant}" if variant), extra ].flatten.compact_blank.join(" ")
    end

    def initialize(label = nil, variant: nil, href: nil, type: "submit", class: nil, **attributes)
      @label = label
      @href = href
      @type = type
      @classes = self.class.classes(variant, binding.local_variable_get(:class))
      @attributes = attributes
    end

    def call
      body = content? ? content : @label
      if @href
        link_to(body, @href, class: @classes, **@attributes)
      else
        content_tag(:button, body, type: @type, class: @classes, **@attributes)
      end
    end
  end
end
