# How far learners have got through a course, lesson by lesson, from Attend's
# own records: a video view row is created when the lesson page loads, its
# progress is timed by the server (TrainingVideoView), and a completion is
# saved once the lesson (and its quiz) is done. The video host's view counts
# can't stand in for this — YouTube misses most plays in an embedded player.
#
# Counts follow each learner's current attempt: restarting a course clears its
# completions and video progress (TrainingEnrollment#restart!).
class TrainingFunnel
  # opened/watched are nil for a lesson with no video: nothing is recorded
  # when someone opens a reading. stopped counts unfinished learners whose
  # next lesson to do is this one.
  Step = Data.define(:lesson, :opened, :watched, :completed, :stopped)

  attr_reader :started, :finished, :steps

  def initialize(course, lessons = course.lessons.to_a)
    enrollments = course.enrollments
    @started = enrollments.count
    @finished = enrollments.where.not(completed_at: nil).count

    in_course = { training_enrollments: { training_course_id: course.id } }
    views = TrainingVideoView.joins(:enrollment).where(in_course)
    opened = views.group(:training_lesson_id).count
    watched = views.where.not(completed_at: nil).group(:training_lesson_id).count
    completions = TrainingLessonCompletion.joins(:enrollment).where(in_course)
    completed = completions.group(:training_lesson_id).count
    stopped = stopped_counts(lessons, enrollments.where(completed_at: nil), completions)

    @steps = lessons.map do |lesson|
      Step.new(
        lesson: lesson,
        opened: (opened.fetch(lesson.id, 0) if lesson.video?),
        watched: (watched.fetch(lesson.id, 0) if lesson.video?),
        completed: completed.fetch(lesson.id, 0),
        stopped: stopped.fetch(lesson.id, 0)
      )
    end
  end

  def percent_of_started(count)
    return if count.nil? || started.zero?

    (count * 100.0 / started).round
  end

  private

  # Lessons open in order, so an unfinished learner's place is the first
  # lesson they haven't completed.
  def stopped_counts(lessons, unfinished, completions)
    done = completions.where(training_enrollment_id: unfinished.select(:id))
      .pluck(:training_enrollment_id, :training_lesson_id)
      .each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) { |(enrollment, lesson), sets| sets[enrollment] << lesson }

    unfinished.pluck(:id).each_with_object(Hash.new(0)) do |enrollment_id, counts|
      next_lesson = lessons.detect { |lesson| !done[enrollment_id].include?(lesson.id) }
      counts[next_lesson.id] += 1 if next_lesson
    end
  end
end
