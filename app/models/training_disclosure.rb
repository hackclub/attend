# A criminal-record declaration made before a course that asks for one
# (TrainingCourse#disclosure_required). Answering yes makes someone
# ineligible to work Hack Club events until the Hack Club Safety Team reviews
# it and either clears or upholds it.
#
# Only global admins see the answer, which is encrypted, along with the
# review note; review_status is left plain so eligibility can be queried.
class TrainingDisclosure < ApplicationRecord
  self.implicit_order_column = "created_at"

  # Ask with the course's own wording, or this default.
  DEFAULT_QUESTION = "Are you on any offenders' register, or have you been convicted of any of the following: " \
    "a sexual offence, a felony, a crime against children, or a misdemeanour?".freeze

  SAFETY_TEAM_NAME = "Hack Club Safety Team".freeze
  SAFETY_TEAM_EMAIL = "safety@hackclub.com".freeze

  # Who's still ineligible: an undecided "yes", or one the Safety Team upheld.
  BLOCKING_STATUSES = %w[pending upheld].freeze

  has_paper_trail skip: %i[answer review_note]

  belongs_to :user
  belongs_to :course, class_name: "TrainingCourse", foreign_key: :training_course_id, optional: true
  belongs_to :enrollment, class_name: "TrainingEnrollment", foreign_key: :training_enrollment_id, optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  encrypts :answer, :review_note

  enum :review_status, {
    not_required: "not_required",
    pending: "pending",
    cleared: "cleared",
    upheld: "upheld"
  }, prefix: :review

  validates :question, presence: true
  validates :answer, inclusion: { in: %w[yes no] }
  validates :review_note, presence: { message: "is required when reviewing a declaration" }, if: -> { review_cleared? || review_upheld? }

  before_validation do
    self.answered_at ||= Time.current
    self.review_status ||= answer == "yes" ? "pending" : "not_required"
  end

  scope :blocking, -> { where(review_status: BLOCKING_STATUSES) }
  scope :newest_first, -> { order(answered_at: :desc) }

  def self.ineligible_user_ids(user_ids)
    blocking.where(user_id: user_ids).distinct.pluck(:user_id).to_set
  end

  def answered_yes?
    answer == "yes"
  end

  def review!(outcome:, by:, note:)
    update!(review_status: outcome, reviewed_by: by, reviewed_at: Time.current, review_note: note)
  end
end
