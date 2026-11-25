module Console
  # Cloudscape's button: normal (2px accent outline), primary (accent fill),
  # link (borderless tertiary) or icon. With `href:` it renders a link that
  # looks like a button; otherwise a <button>, type="button" unless told
  # otherwise. Behind `cs_button`.
  #
  #   <%= cs_button "Add staff", variant: :primary, type: "submit" %>
  #   <%= cs_button "Clear filters", href: admin_bans_path %>
  #
  # For builders that emit their own element (`f.button`, `button_to`), take
  # the class string from `ButtonComponent.classes(variant: :primary)`.
  class ButtonComponent < ApplicationComponent
    VARIANTS = %i[primary link icon].freeze

    def self.classes(variant: nil, full: false, extra: nil)
      variant = variant&.to_sym
      raise ArgumentError, "unknown cs-btn variant: #{variant.inspect}" if variant && VARIANTS.exclude?(variant)

      [ "cs-btn", ("cs-btn-#{variant}" if variant), ("cs-btn-full" if full), extra ].flatten.compact_blank.join(" ")
    end

    def initialize(label = nil, variant: nil, href: nil, type: "button", full: false, class: nil, **attributes)
      @label = label
      @href = href
      @type = type
      @classes = self.class.classes(variant: variant, full: full, extra: binding.local_variable_get(:class))
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
