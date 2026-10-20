# A series' onboarding branding: a few colours, fonts and images an admin
# picks on the series, expanded into the full set of light-theme tokens the
# portal reads (themes.css) and held to the same WCAG contrast floors.
#
# Fonts and images are files in the repo (FONTS below, and
# app/assets/images/brands/), so adding a brand means pushing its assets and
# then filling this in on the series. Nothing in the app is specific to any
# one brand.
#
# Only the light theme takes the colours. Someone who picked another theme
# keeps it, with the brand's fonts and artwork on top.
class BrandTheme
  include ActiveModel::Model

  COLOR_FIELDS = %w[background ink accent accent_fill secondary highlight card_from card_to].freeze
  REQUIRED_COLORS = %w[background ink accent].freeze
  FONT_FIELDS = %w[body_font heading_font].freeze
  IMAGE_FIELDS = %w[logo_image mascot_image footer_image tshirt_image].freeze
  NAV_STYLES = %w[steps progress].freeze
  FIELDS = (COLOR_FIELDS + FONT_FIELDS + IMAGE_FIELDS + %w[nav_style tokens]).freeze

  IMAGE_ROOT = "brands"
  IMAGE_EXTENSIONS = %w[webp png jpg jpeg gif svg].freeze

  # Self-hosted fonts, declared in app/assets/tailwind/brand.css. The CSP
  # allows no font hosts, so a new font means adding its files there and a
  # row here. Single-weight fonts turn off faux bold on branded pages.
  FONTS = {
    "jua" => { name: "Jua", families: [ "Jua Extras", "Jua" ], single_weight: true },
    "darumadrop-one" => { name: "Darumadrop One", families: [ "Darumadrop One" ], single_weight: true }
  }.freeze
  GENERIC_FONT_STACK = "ui-rounded, system-ui, sans-serif".freeze

  # Tokens derived from the colours above. Any of them can be pinned to an
  # exact value in `tokens`; the contrast checks run on the final values.
  # The theme tokens shadow themes.css; the brand-* ones only exist on
  # branded pages.
  THEME_TOKENS = %w[
    bg-app bg-elev bg-elev-2 bg-elev-3 bg-sunken
    text-strong text text-soft text-muted text-faint text-link
    border-soft border border-strong border-card
    accent accent-strong accent-fill focus-ring
    success success-strong success-text
  ].freeze
  BRAND_TOKENS = %w[accent-fill-hover done-fill highlight card-from card-to].freeze
  TOKENS = (THEME_TOKENS + BRAND_TOKENS).freeze

  # WCAG 1.4.3: words. Checked on the page background and on cards.
  TEXT_TOKENS = %w[text-strong text text-soft text-muted text-link accent-strong success-text].freeze
  # Shades stepped from the ink: when the ink itself fails on a surface,
  # these fail with it, so only the ink is reported.
  INK_SHADES = %w[text text-soft text-muted].freeze
  # WCAG 1.4.11: form control outlines and focus indicators.
  NON_TEXT_TOKENS = %w[border-strong focus-ring].freeze
  # Fills that carry white text (buttons, the done step marker).
  FILL_TOKENS = %w[accent-fill accent-fill-hover done-fill].freeze
  TEXT_RATIO = 4.5
  NON_TEXT_RATIO = 3.0

  # Plain names for contrast errors; pinned tokens keep their token name.
  TOKEN_LABELS = {
    "text-strong" => "Text colour", "text" => "Body text", "text-soft" => "Secondary text",
    "text-muted" => "Hint text", "text-link" => "Link colour", "accent-strong" => "Accent text",
    "success-text" => "Success text", "border-strong" => "Form outline", "focus-ring" => "Focus ring",
    "accent-fill" => "the button colour", "accent-fill-hover" => "the button hover colour",
    "done-fill" => "the completed-step colour", "bg-app" => "the page background", "bg-elev" => "cards",
    "card-from" => "the event card gradient start", "card-to" => "the event card gradient end"
  }.freeze

  HEX = /\A#\h{6}\z/
  WHITE = "#ffffff".freeze

  attr_reader :settings

  validate :validate_fields

  def self.image_options
    root = Rails.root.join("app/assets/images")
    Dir.glob(root.join(IMAGE_ROOT, "**", "*.{#{IMAGE_EXTENSIONS.join(",")}}")).map do |path|
      Pathname.new(path).relative_path_from(root).to_s
    end.sort
  end

  def self.font_options
    FONTS.map { |key, font| [ font[:name], key ] }
  end

  # `tokens` may come in as a hash or as the admin form's text area: one
  # `name: #hex` per line, with or without the leading `--`.
  def self.parse_tokens(value)
    return value.to_h.transform_keys(&:to_s) if value.is_a?(Hash) || value.is_a?(ActionController::Parameters)

    value.to_s.lines.each_with_object({}) do |line, tokens|
      name, color = line.split(":", 2).map { |part| part.to_s.strip }
      next if name.blank? && color.blank?

      tokens[name.delete_prefix("--")] = color.to_s.downcase
    end
  end

  # Turns the series form's params into what gets stored: blanks dropped,
  # colours lowercased, the tokens text area parsed.
  def self.normalize(params)
    params = params.to_h.stringify_keys.slice(*FIELDS)
    params["tokens"] = parse_tokens(params["tokens"])
    params.each_with_object({}) do |(key, value), clean|
      value = value.strip.downcase if value.is_a?(String) && COLOR_FIELDS.include?(key)
      value = value.strip if value.is_a?(String)
      clean[key] = value if value.present?
    end
  end

  def initialize(settings = {})
    @settings = (settings || {}).to_h.stringify_keys
    @settings["tokens"] = self.class.parse_tokens(@settings["tokens"]) if @settings.key?("tokens")
  end

  # A brand applies once its required colours are set.
  def active?
    REQUIRED_COLORS.all? { |field| settings[field].present? }
  end

  FIELDS.each do |field|
    define_method(field) { settings[field] }
  end

  def tokens_text
    (settings["tokens"] || {}).map { |name, color| "#{name}: #{color}" }.join("\n")
  end

  def nav_style
    NAV_STYLES.include?(settings["nav_style"]) ? settings["nav_style"] : "steps"
  end

  def body_font_stack
    font_stack(body_font)
  end

  def heading_font_stack
    return unless heading_font

    families = FONTS.dig(heading_font, :families).to_a + FONTS.dig(body_font, :families).to_a
    (families.uniq.map { |family| %("#{family}") } + [ GENERIC_FONT_STACK ]).join(", ")
  end

  def single_weight_body?
    FONTS.dig(body_font, :single_weight) || false
  end

  # The final light-theme token values: derived, then pinned overrides.
  def resolved_tokens
    @resolved_tokens ||= derived_tokens.merge(valid_overrides)
  end

  def contrast_failures
    return [] unless active? && colors_valid?

    tokens = resolved_tokens
    failures = []
    TEXT_TOKENS.each do |token|
      # Without a secondary colour the theme's own success tokens stay.
      next unless tokens[token]

      %w[bg-app bg-elev].each do |surface|
        next if INK_SHADES.include?(token) && failures.include?([ "text-strong", surface, TEXT_RATIO ])

        failures << [ token, surface, TEXT_RATIO ] if self.class.contrast(tokens[token], tokens[surface]) < TEXT_RATIO
      end
    end
    %w[card-from card-to].each do |surface|
      failures << [ "text-strong", surface, TEXT_RATIO ] if self.class.contrast(tokens["text-strong"], tokens[surface]) < TEXT_RATIO
    end
    NON_TEXT_TOKENS.each do |token|
      %w[bg-app bg-elev].each do |surface|
        failures << [ token, surface, NON_TEXT_RATIO ] if self.class.contrast(tokens[token], tokens[surface]) < NON_TEXT_RATIO
      end
    end
    FILL_TOKENS.each do |token|
      failures << [ "white text", token, TEXT_RATIO ] if self.class.contrast(WHITE, tokens[token]) < TEXT_RATIO
    end
    failures.map do |subject, surface, floor|
      foreground = subject == "white text" ? WHITE : tokens[subject]
      background = tokens[surface]
      { subject: subject, surface: surface, floor: floor, ratio: self.class.contrast(foreground, background).floor(2) }
    end
  end

  # --- colour maths (sRGB, WCAG 2.x) ----------------------------------

  def self.rgb(hex)
    hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
  end

  def self.hex(rgb)
    "#" + rgb.map { |channel| channel.round.clamp(0, 255).to_s(16).rjust(2, "0") }.join
  end

  # `amount` of the way from a to b.
  def self.mix(a, b, amount)
    hex(rgb(a).zip(rgb(b)).map { |x, y| x + (y - x) * amount })
  end

  def self.scale(color, factor)
    hex(rgb(color).map { |channel| channel * factor })
  end

  def self.rgba(color, alpha)
    "rgb(#{rgb(color).join(" ")} / #{alpha})"
  end

  def self.luminance(color)
    r, g, b = rgb(color).map do |channel|
      c = channel / 255.0
      c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
    end
    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  def self.contrast(a, b)
    la, lb = [ luminance(a), luminance(b) ].sort.reverse
    (la + 0.05) / (lb + 0.05)
  end

  private

  def font_stack(key)
    return unless key && FONTS[key]

    (FONTS[key][:families].map { |family| %("#{family}") } + [ GENERIC_FONT_STACK ]).join(", ")
  end

  def colors_valid?
    COLOR_FIELDS.all? { |field| settings[field].blank? || settings[field].match?(HEX) }
  end

  def valid_overrides
    (settings["tokens"] || {}).select { |name, color| TOKENS.include?(name) && color.to_s.match?(HEX) }
  end

  def derived_tokens
    bg = background
    highlight_color = highlight.presence || accent
    fill = accent_fill.presence || darken_until(accent, against: [ WHITE ], ratio: TEXT_RATIO)
    surfaces = [ bg, WHITE ]

    tokens = {
      "bg-app" => bg,
      "bg-elev" => WHITE,
      "bg-elev-2" => self.class.mix(bg, WHITE, 0.5),
      "bg-elev-3" => self.class.mix(bg, highlight_color, 0.06),
      "bg-sunken" => self.class.mix(bg, highlight_color, 0.25),
      "text-strong" => ink,
      "text" => text_tone(0.08, surfaces),
      "text-soft" => text_tone(0.16, surfaces),
      "text-muted" => text_tone(0.3, surfaces),
      "text-faint" => self.class.mix(ink, bg, 0.45),
      "text-link" => darken_until(fill, against: surfaces, ratio: TEXT_RATIO),
      "border-soft" => self.class.mix(bg, ink, 0.05),
      "border" => self.class.mix(bg, ink, 0.12),
      "border-card" => self.class.mix(bg, ink, 0.16),
      "border-strong" => darken_until(self.class.mix(ink, bg, 0.45), against: surfaces, ratio: NON_TEXT_RATIO),
      "accent" => accent,
      "accent-strong" => darken_until(fill, against: surfaces, ratio: TEXT_RATIO),
      "accent-fill" => fill,
      "accent-fill-hover" => darken_until(self.class.scale(fill, 0.84), against: [ WHITE ], ratio: TEXT_RATIO),
      "focus-ring" => darken_until(fill, against: surfaces, ratio: NON_TEXT_RATIO),
      "highlight" => highlight_color,
      "card-from" => card_from.presence || self.class.mix(highlight_color, WHITE, 0.7),
      "card-to" => card_to.presence || self.class.mix(highlight_color, WHITE, 0.5)
    }

    if secondary.present?
      tokens.merge!(
        "success" => secondary,
        "success-strong" => self.class.scale(secondary, 0.82),
        "success-text" => darken_until(secondary, against: surfaces, ratio: TEXT_RATIO),
        "done-fill" => darken_until(secondary, against: [ WHITE ], ratio: TEXT_RATIO)
      )
    else
      tokens["done-fill"] = fill
    end
    tokens
  end

  # A step from ink towards the background, pulled back towards ink until it
  # reads as text on every surface.
  def text_tone(amount, surfaces)
    amount -= 0.02 while amount.positive? && surfaces.any? { |surface| self.class.contrast(self.class.mix(ink, background, amount), surface) < TEXT_RATIO }
    self.class.mix(ink, background, amount.clamp(0, 1))
  end

  def darken_until(color, against:, ratio:)
    48.times do
      return color if against.all? { |surface| self.class.contrast(color, surface) >= ratio }

      color = self.class.scale(color, 0.97)
    end
    color
  end

  def validate_fields
    REQUIRED_COLORS.each do |field|
      errors.add(field, :blank) if settings[field].blank? && configured_at_all?
    end
    COLOR_FIELDS.each do |field|
      errors.add(field, "must be a hex colour like #1a2b3c") if settings[field].present? && !settings[field].match?(HEX)
    end
    FONT_FIELDS.each do |field|
      errors.add(field, :inclusion) if settings[field].present? && !FONTS.key?(settings[field])
    end
    IMAGE_FIELDS.each do |field|
      errors.add(field, "isn't an image under app/assets/images/#{IMAGE_ROOT}/") if settings[field].present? && !self.class.image_options.include?(settings[field])
    end
    errors.add(:nav_style, :inclusion) if settings["nav_style"].present? && !NAV_STYLES.include?(settings["nav_style"])

    (settings["tokens"] || {}).each do |name, color|
      if !TOKENS.include?(name)
        errors.add(:tokens, "has an unknown token: #{name}")
      elsif !color.to_s.match?(HEX)
        errors.add(:tokens, "#{name} must be a hex colour like #1a2b3c")
      end
    end

    contrast_failures.each do |failure|
      subject = TOKEN_LABELS.fetch(failure[:subject], failure[:subject]).upcase_first
      surface = TOKEN_LABELS.fetch(failure[:surface], failure[:surface])
      errors.add(:base, "#{subject} on #{surface} is #{failure[:ratio]}:1, below the #{failure[:floor]}:1 minimum")
    end
  end

  # Fonts, images or copy alone don't need colours; any colour does.
  def configured_at_all?
    COLOR_FIELDS.any? { |field| settings[field].present? } || settings["tokens"].present?
  end
end
