class TrainingBadge < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  # Who can be required to hold a badge: every event role, plus volunteers,
  # who are on an event's roster without a role (see EventVolunteer). Series
  # owners and organizers act as event admins, so they count as event_admin.
  REQUIRABLE_ROLES = (EventRoleAssignment.roles.keys + [ "volunteer" ]).freeze

  # Required of anyone working an event, whatever their role — including
  # roles added after the badge was set up.
  EVERYONE = "everyone".freeze

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
  before_validation do
    roles = Array(required_roles).compact_blank.uniq
    self.required_roles = roles.include?(EVERYONE) ? [ EVERYONE ] : roles
  end

  scope :ordered, -> { order(:position, :name) }
  scope :required_for, ->(role) { required_of_any([ role ]) }
  scope :required, -> { where("cardinality(required_roles) > 0") }
  # Badges at least one of these roles needs.
  scope :required_of_any, ->(roles) { where("required_roles && ARRAY[?]::varchar[]", roles.map(&:to_s) + [ EVERYONE ]) }

  def self.role_label(role)
    case role.to_s
    when EVERYONE then "Everyone working an event"
    when "volunteer" then "Volunteer"
    else EventRoleAssignment::ROLE_DETAILS.dig(role.to_s, :label) || role.to_s.titleize
    end
  end

  def required?
    required_roles.any?
  end

  def required_of_everyone?
    required_roles.include?(EVERYONE)
  end

  # Whether someone holding these roles at an event must hold this badge.
  def required_for?(roles)
    roles = Array(roles).map(&:to_s)
    roles.any? && (required_of_everyone? || (required_roles & roles).any?)
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
    unknown = required_roles - REQUIRABLE_ROLES - [ EVERYONE ]
    errors.add(:required_roles, "includes an unknown role: #{unknown.join(", ")}") if unknown.any?
  end
end
