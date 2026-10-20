# Renders an event's onboarding branding (BrandTheme) into the layout: the
# <html> attributes brand.css keys off, and the token values as a <style>.
module BrandHelper
  # Labels and hints for the branding fields on the series forms (classic
  # and console admin).
  BRAND_COLOR_FIELDS = {
    "background" => [ "Page background", "Required. The page behind the cards." ],
    "ink" => [ "Text colour", "Required. Body text and headings; lighter text shades are mixed from it." ],
    "accent" => [ "Accent", "Required. Progress bars and decoration. Never used for text." ],
    "accent_fill" => [ "Button colour", "White button text sits on it. Worked out from the accent when blank." ],
    "secondary" => [ "Secondary", "Completed steps and success states. When blank, completed steps use the button colour and success states keep Attend's green." ],
    "highlight" => [ "Highlight", "Tints info notes and surfaces. The accent when blank." ],
    "card_from" => [ "Event card gradient start", "Worked out from the highlight when blank." ],
    "card_to" => [ "Event card gradient end", "Worked out from the highlight when blank." ]
  }.freeze

  BRAND_IMAGE_FIELDS = {
    "logo_image" => [ "Logo", "Above the event card on the welcome screen." ],
    "mascot_image" => [ "Mascot", "On the event card." ],
    "footer_image" => [ "Footer artwork", "Repeated along the bottom of every onboarding page." ],
    "tshirt_image" => [ "T-shirt", "Next to the t-shirt size question." ]
  }.freeze

  def brand_image_options_for_select(selected)
    options_for_select([ [ "None", "" ] ] + BrandTheme.image_options.map { |path| [ path.delete_prefix("#{BrandTheme::IMAGE_ROOT}/"), path ] }, selected)
  end

  def brand_font_options_for_select(selected)
    options_for_select([ [ "Attend default", "" ] ] + BrandTheme.font_options, selected)
  end

  def brand_nav_options_for_select(selected)
    options_for_select([ [ "Numbered steps", "steps" ], [ "Progress bar", "progress" ] ], selected)
  end

  # Admin form errors for one branding field, e.g. :brand_background.
  def brand_field_errors(series, field)
    series.errors.full_messages_for(:"brand_#{field}")
  end
  # Attributes for <html>. Fonts and artwork apply on every theme; the
  # colours only on light, so dark-theme users keep their theme.
  def brand_html_attributes(brand)
    return {} unless brand

    {
      "data-branded" => "",
      "data-brand-body-font" => ("" if brand.body_font_stack),
      "data-brand-heading-font" => ("" if brand.heading_font_stack),
      "data-brand-single-weight" => ("" if brand.single_weight_body?)
    }.compact
  end

  def brand_style_tag(brand)
    return unless brand

    tokens = brand.resolved_tokens
    palette = tokens.map do |name, value|
      prefix = BrandTheme::BRAND_TOKENS.include?(name) ? "--brand-" : "--"
      "#{prefix}#{name}: #{value};"
    end
    palette += [
      "--accent-soft: #{BrandTheme.rgba(tokens["accent"], 0.1)};",
      "--brand-glow-1: #{BrandTheme.rgba(tokens["accent"], 0.3)};",
      "--brand-glow-2: #{BrandTheme.rgba(tokens["success"] || tokens["highlight"], 0.35)};",
      "--shadow-sm: 0 1px 2px #{BrandTheme.rgba(tokens["text-strong"], 0.08)};",
      "--shadow-md: 0 6px 16px #{BrandTheme.rgba(tokens["text-strong"], 0.1)};",
      "--shadow-lg: 0 12px 32px #{BrandTheme.rgba(tokens["text-strong"], 0.14)};"
    ]
    palette << "--success-soft: #{BrandTheme.rgba(tokens["success"], 0.16)};" if tokens["success"]

    always = []
    always << "--brand-font-body: #{brand.body_font_stack};" if brand.body_font_stack
    always << "--brand-font-heading: #{brand.heading_font_stack};" if brand.heading_font_stack
    always << "--brand-footer-image: url(\"#{asset_path(brand.footer_image)}\");" if brand.footer_image

    # Unlayered, like themes.css, and more specific than its
    # [data-theme="light"] block.
    css = +""
    css << "html[data-branded] { #{always.join(" ")} }\n" if always.any?
    css << "html[data-branded][data-theme=\"light\"] { #{palette.join(" ")} color-scheme: light; }"
    content_tag(:style, css.html_safe)
  end

  # "Downtown Library, Boston": venue and city, whichever are set.
  def event_card_location(event)
    [ event.venue_name, event.location_city ].filter_map(&:presence).uniq.join(", ")
  end
end
