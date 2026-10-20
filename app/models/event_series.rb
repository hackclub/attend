class EventSeries < ApplicationRecord
  include RasterizesSvgLogo
  include DecodableImageAttachment

  has_paper_trail

  self.implicit_order_column = "created_at"

  has_one_attached :logo
  has_one_attached :banner

  validate :acceptable_logo
  validate :acceptable_banner

  has_many :events, dependent: :nullify
  has_many :series_role_assignments, dependent: :destroy
  has_many :members, through: :series_role_assignments, source: :user
  has_many :series_api_tokens, dependent: :destroy

  RESERVED_SLUGS = %w[new].freeze

  # Account linking modes for the onboarding accounts step.
  ACCOUNT_LINKING_MODES = %w[off optional required].freeze
  ACCOUNT_LINKING_PROVIDERS = %w[github itch].freeze

  # Settings every event in the series inherits: onboarding branding (see
  # BrandTheme), notes shown during registration, and account linking modes
  # with an optional how-to link per provider. Events can override linking.
  store_accessor :config, :brand, :registration_note, :address_note, :tshirt_note,
    :github_linking, :itch_linking, :github_help_url, :itch_help_url

  validates :github_linking, :itch_linking, inclusion: { in: ACCOUNT_LINKING_MODES }, allow_blank: true
  validates :github_help_url, :itch_help_url, format: { with: %r{\Ahttps://\S+\z}, message: "must start with https://" }, allow_blank: true
  validate :brand_meets_contrast_floors

  validates :name, presence: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :slug, presence: true,
                   uniqueness: true,
                   format: { with: /\A[a-z0-9-]+\z/, message: "must be lowercase with no spaces (dashes allowed)" },
                   exclusion: { in: RESERVED_SLUGS, message: "is reserved and cannot be used" }

  before_validation :generate_slug_from_name, if: -> { slug.blank? && name.present? }

  def to_param
    slug
  end

  def effective_logo
    logo if logo.attached?
  end

  def brand=(value)
    super(BrandTheme.normalize(value || {}))
  end

  def brand_theme
    BrandTheme.new(brand)
  end

  def account_linking_mode(provider)
    mode = config&.[]("#{provider}_linking")
    ACCOUNT_LINKING_MODES.include?(mode) ? mode : "off"
  end

  def account_help_url(provider)
    config&.[]("#{provider}_help_url").presence
  end

  def logo_displayable?
    return true if logo.attached? && logo.content_type == "image/svg+xml"

    displayable_image?(logo)
  end

  private

  def generate_slug_from_name
    self.slug = name.downcase.gsub(/\s+/, "-").gsub(/[^a-z0-9-]/, "")
  end

  def brand_meets_contrast_floors
    theme = brand_theme
    return if theme.valid?

    theme.errors.each do |error|
      errors.add(error.attribute == :base ? :brand : :"brand_#{error.attribute}", error.message)
    end
  end

  def acceptable_logo
    return unless attachment_changes["logo"].present?

    unless Event::ALLOWED_LOGO_CONTENT_TYPES.include?(logo.content_type)
      errors.add(:logo, "must be a JPEG, PNG, GIF, WebP, or SVG image")
    end

    if logo.byte_size && logo.byte_size > Event::MAX_LOGO_BYTE_SIZE
      errors.add(:logo, "must be smaller than 5MB")
    end

    validate_decodable_image(:logo)
  end

  def acceptable_banner
    return unless attachment_changes["banner"].present?

    unless Event::ALLOWED_BANNER_CONTENT_TYPES.include?(banner.content_type)
      errors.add(:banner, "must be a PNG or JPEG image")
    end

    if banner.byte_size && banner.byte_size > Event::MAX_BANNER_BYTE_SIZE
      errors.add(:banner, "must be smaller than 5MB")
    end

    validate_decodable_image(:banner)
  end
end
