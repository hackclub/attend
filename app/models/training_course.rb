class TrainingCourse < ApplicationRecord
  include TrainingPositioned

  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :badge, class_name: "TrainingBadge", foreign_key: :training_badge_id, optional: true
  has_many :lessons, -> { ordered }, class_name: "TrainingLesson", dependent: :destroy, inverse_of: :course
  has_many :enrollments, class_name: "TrainingEnrollment", dependent: :destroy
  has_many :invitations, class_name: "TrainingCourseInvitation", dependent: :destroy
  has_many :disclosures, class_name: "TrainingDisclosure", dependent: :nullify

  enum :status, { draft: "draft", published: "published", archived: "archived" }, default: :draft

  # When a learner is shown which answers were right. after_pass keeps a
  # failed attempt from being fixed by copying the answers; they still see
  # which questions they got wrong and why their choice was wrong.
  enum :reveal_answers, { after_pass: "after_pass", every_attempt: "every_attempt" },
    default: :after_pass, prefix: :reveal_answers

  # Who can take it: invite_only courses are for people invited by hand or
  # whose event role needs the badge (see TrainingAccess); open ones are for
  # anyone signed in.
  enum :access, { invite_only: "invite_only", open: "open" }, default: :invite_only, prefix: :access

  validates :title, presence: true
  # /training/badges is the learner's badge page, so no course can take it.
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/ },
    exclusion: { in: %w[badges], message: "is reserved" }
  validates :pass_mark, numericality: { only_integer: true, in: 1..100 }
  validates :estimated_minutes, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :publishable, if: -> { published? && will_save_change_to_status? }

  before_validation :generate_slug, if: -> { slug.blank? && title.present? }

  def to_param
    slug
  end

  def disclosure_question_text
    disclosure_question.presence || TrainingDisclosure::DEFAULT_QUESTION
  end

  def question_count
    lessons.sum { |lesson| lesson.questions.size }
  end

  private

  def siblings
    TrainingCourse.all
  end

  def generate_slug
    self.slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  end

  # A published course with nothing in it would award its badge on a single
  # click, so it needs at least one lesson, every quiz question needs a right
  # answer to be markable, and every must-watch video needs a known length.
  def publishable
    if lessons.empty?
      errors.add(:status, "can't be published until the course has a lesson")
    elsif (unanswerable = lessons.flat_map(&:questions).reject(&:answerable?)).any?
      errors.add(:status, "can't be published while #{unanswerable.size == 1 ? "a question has" : "#{unanswerable.size} questions have"} no correct answer")
    elsif (unknown = lessons.select { |lesson| lesson.watch_required? && lesson.known_video_duration.nil? }).any?
      errors.add(:status, "can't be published until Attend knows how long #{unknown.map { |lesson| "“#{lesson.title}”" }.to_sentence}'s video is — re-save the lesson to look it up, play it once in the preview, or enter its length on the lesson")
    end
  end
end
