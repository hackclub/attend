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

  RESERVED_SLUGS = %w[new].freeze

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

  def logo_displayable?
    return true if logo.attached? && logo.content_type == "image/svg+xml"

    displayable_image?(logo)
  end

  private

  def generate_slug_from_name
    self.slug = name.downcase.gsub(/\s+/, "-").gsub(/[^a-z0-9-]/, "")
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
