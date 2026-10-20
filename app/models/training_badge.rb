class TrainingBadge < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  # Who can be required to hold a badge: every event role, plus volunteers,
  # who are on an event's roster without a role (see EventVolunteer).
  REQUIRABLE_ROLES = (EventRoleAssignment.roles.keys + [ "volunteer" ]).freeze

  # How far ahead of expiry a badge starts showing as due for renewal.
  RENEWAL_WINDOW = 30.days

  has_many :courses, class_name: "TrainingCourse", dependent: :nullify
  has_many :awards, class_name: "TrainingBadgeAward", dependent: :restrict_with_error

  # Artwork shown on badge pages, the public verification page and its link
  # previews. Optional: a shield stands in without it.
  has_one_attached :image

  IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  validate :acceptable_image, if: -> { image.attached? }

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/ }
  validates :validity_months, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :required_roles_are_known

  before_validation :generate_slug, if: -> { slug.blank? && name.present? }
  before_validation { self.required_roles = Array(required_roles).compact_blank.uniq }

  scope :ordered, -> { order(:position, :name) }
  scope :required_for, ->(role) { where("? = ANY(required_roles)", role.to_s) }
  scope :required, -> { where("cardinality(required_roles) > 0") }

  def self.role_label(role)
    role.to_s == "volunteer" ? "Volunteer" : EventRoleAssignment::ROLE_DETAILS.dig(role.to_s, :label) || role.to_s.titleize
  end

  def required?
    required_roles.any?
  end

  def expires?
    validity_months.present?
  end

  private

  def generate_slug
    self.slug = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  end

  def acceptable_image
    errors.add(:image, "must be a PNG, JPEG or WebP") unless image.blob.content_type.in?(IMAGE_CONTENT_TYPES)
    errors.add(:image, "must be smaller than 5 MB") if image.blob.byte_size > 5.megabytes
  end

  def required_roles_are_known
    unknown = required_roles - REQUIRABLE_ROLES
    errors.add(:required_roles, "includes an unknown role: #{unknown.join(", ")}") if unknown.any?
  end
end
