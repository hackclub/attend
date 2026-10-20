class TrainingBadgeAward < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :user
  belongs_to :badge, class_name: "TrainingBadge", foreign_key: :training_badge_id
  belongs_to :course, class_name: "TrainingCourse", foreign_key: :training_course_id, optional: true
  belongs_to :awarded_by, class_name: "User", optional: true
  belongs_to :revoked_by, class_name: "User", optional: true

  validates :awarded_at, presence: true
  validate :expires_after_award
  validates :note, presence: { message: "is required when awarding a badge by hand — say where the training was done" },
    if: -> { course.nil? && awarded_by.present? }

  before_validation { self.awarded_at ||= Time.current }

  scope :unrevoked, -> { where(revoked_at: nil) }
  scope :current, -> { unrevoked.where("training_badge_awards.expires_at IS NULL OR training_badge_awards.expires_at > ?", Time.current) }
  scope :newest_first, -> { order(awarded_at: :desc) }

  def manual?
    course.nil?
  end

  def revoked?
    revoked_at.present?
  end

  def expired?(now = Time.current)
    expires_at.present? && expires_at <= now
  end

  def current?(now = Time.current)
    !revoked? && !expired?(now)
  end

  def expiring_soon?(now = Time.current)
    current?(now) && expires_at.present? && expires_at <= now + TrainingBadge::RENEWAL_WINDOW
  end

  def revoke!(by:, reason: nil)
    update!(revoked_at: Time.current, revoked_by: by, revoked_reason: reason.presence)
  end

  private

  def expires_after_award
    return if expires_at.blank? || awarded_at.blank?

    errors.add(:expires_at, "must be after the award date") if expires_at <= awarded_at
  end
end
