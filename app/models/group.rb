class Group < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event
  has_many :group_memberships, dependent: :destroy
  has_many :participant_events, through: :group_memberships

  before_validation :generate_slug_from_name, if: -> { slug.blank? && name.present? }

  validates :name, presence: true, uniqueness: { scope: :event_id, case_sensitive: false }
  validates :slug, presence: true,
                   uniqueness: { scope: :event_id },
                   format: { with: /\A[a-z0-9-]+\z/, message: "must be lowercase with no spaces (dashes allowed)" }
  validates :color, format: { with: /\A#?[0-9a-fA-F]{6}\z/, message: "must be a 6-digit hex" }, allow_blank: true

  scope :ordered, -> { order(:position, :name) }

  def normalized_color
    return nil if color.blank?
    color.start_with?("#") ? color : "##{color}"
  end

  def member_count
    group_memberships.count
  end

  private

  def generate_slug_from_name
    self.slug = name.downcase.gsub(/\s+/, "-").gsub(/[^a-z0-9-]/, "")
  end
end
