class TrainingEnrollment < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :user
  belongs_to :course, class_name: "TrainingCourse", foreign_key: :training_course_id
  has_many :lesson_completions, class_name: "TrainingLessonCompletion", dependent: :destroy
  has_many :quiz_attempts, class_name: "TrainingQuizAttempt", dependent: :destroy
  has_many :video_views, class_name: "TrainingVideoView", dependent: :destroy
  has_many :disclosures, class_name: "TrainingDisclosure", dependent: :nullify

  validates :training_course_id, uniqueness: { scope: :user_id }

  before_validation { self.started_at ||= Time.current }

  def completed?
    completed_at.present?
  end

  def completed_lesson_ids
    @completed_lesson_ids ||= lesson_completions.pluck(:training_lesson_id).to_set
  end

  def lesson_completed?(lesson)
    completed_lesson_ids.include?(lesson.id)
  end

  # Lessons open in order: the first one, plus each one whose predecessor is
  # done. A completed course stays fully open for review.
  def lesson_unlocked?(lesson)
    return true if completed?

    lessons = course.lessons.to_a
    index = lessons.index(lesson)
    index.nil? || index.zero? || lesson_completed?(lessons[index - 1])
  end

  # The declaration for this attempt at the course. Asked again on a restart,
  # so it's re-confirmed whenever the badge is earned or renewed.
  def current_disclosure
    disclosures.where(answered_at: started_at..).order(:answered_at).last
  end

  def disclosure_needed?
    course.disclosure_required? && current_disclosure.nil?
  end

  def video_view_for(lesson)
    video_views.find_or_create_by!(training_lesson_id: lesson.id)
  rescue ActiveRecord::RecordNotUnique
    video_views.find_by!(training_lesson_id: lesson.id)
  end

  # Whether the lesson's video gate is open: no watching required, already
  # done (a lesson finished before a video was added stays finished), or
  # watched through.
  def video_watched?(lesson)
    return true unless lesson.watch_required?
    return true if lesson_completed?(lesson)

    video_views.where(training_lesson_id: lesson.id).where.not(completed_at: nil).exists?
  end

  def next_lesson
    course.lessons.detect { |lesson| !lesson_completed?(lesson) }
  end

  def progress_percent
    total = course.lessons.size
    return 0 if total.zero?

    ((course.lessons.count { |lesson| lesson_completed?(lesson) }.to_f / total) * 100).round
  end

  # Records a lesson as done and, once every lesson is, finishes the course and
  # awards its badge. Returns the new award when this call finished the course.
  def complete_lesson!(lesson, score: nil)
    award = nil
    transaction do
      lock!
      completion = lesson_completions.find_or_initialize_by(training_lesson_id: lesson.id)
      completion.completed_at ||= Time.current
      completion.score = [ completion.score, score ].compact.max
      completion.save!
      @completed_lesson_ids = nil

      if !completed? && course.lessons.all? { |l| lesson_completed?(l) }
        update!(completed_at: Time.current)
        award = award_badge!
      end
    end
    award
  end

  # Start the course over — to renew a badge that's expiring, or after one was
  # revoked. Quiz attempts are kept as history; awards are untouched. Videos
  # have to be watched again.
  def restart!
    transaction do
      lesson_completions.destroy_all
      video_views.destroy_all
      update!(started_at: Time.current, completed_at: nil)
      @completed_lesson_ids = nil
    end
  end

  private

  # A draft course can be walked through by admins to check it, but only a
  # published one awards anything.
  def award_badge!
    return if course.badge.nil? || !course.published?
    # Someone the Safety Team hasn't cleared can't earn a badge.
    return unless user.eligible_to_work_events?

    TrainingBadgeAward.create!(
      user: user,
      badge: course.badge,
      course: course,
      awarded_at: completed_at,
      expires_at: course.badge.validity_months&.months&.since(completed_at)
    )
  end
end
