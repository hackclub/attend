module Training
  class LessonsController < BaseController
    before_action :set_course
    before_action :require_enrollment
    before_action :set_lesson
    before_action :require_unlocked
    before_action :require_video_watched, only: [ :complete, :quiz ]

    def show
      @attempt = @enrollment.quiz_attempts.find_by(id: params[:attempt], training_lesson_id: @lesson.id) if params[:attempt]
      # Created on page load so the server's watch clock starts here, not at
      # the first heartbeat (TrainingVideoView#record_heartbeat!).
      @video_view = @enrollment.video_view_for(@lesson) if @lesson.watch_required? && !@enrollment.lesson_completed?(@lesson)
    end

    def complete
      if @lesson.quiz?
        redirect_to training_course_lesson_path(@course, @lesson), alert: "Answer the questions to finish this lesson."
        return
      end

      award = @enrollment.complete_lesson!(@lesson)
      next_lesson = @course.lessons[@lesson_index + 1]

      if award
        redirect_to training_award_path(award), notice: "Course complete — you've earned #{award.badge.name}."
      elsif next_lesson && !@enrollment.completed?
        redirect_to training_course_lesson_path(@course, next_lesson)
      else
        redirect_to training_course_path(@course), notice: (@enrollment.completed? ? "Course complete." : nil)
      end
    end

    # Every attempt, pass or fail, lands on a review of it (show with
    # ?attempt=), so the learner sees what they got right and why.
    def quiz
      unless @lesson.quiz?
        redirect_to training_course_lesson_path(@course, @lesson)
        return
      end

      @answers = params[:answers]&.to_unsafe_h || {}
      unanswered = @lesson.questions.reject { |question| Array(@answers[question.id]).compact_blank.any? }
      if unanswered.any?
        @unanswered_ids = unanswered.map(&:id)
        flash.now[:alert] = "Answer every question before submitting — #{unanswered.size == 1 ? "one is" : "#{unanswered.size} are"} still blank."
        show
        render :show, status: :unprocessable_entity
        return
      end

      attempt = TrainingQuizAttempt.grade(enrollment: @enrollment, lesson: @lesson, answers: @answers)
      if attempt.passed?
        award = @enrollment.complete_lesson!(@lesson, score: attempt.score)
        notice = award ? "You passed with #{attempt.score}% and earned #{award.badge.name}." : "You passed with #{attempt.score}%."
        redirect_to training_course_lesson_path(@course, @lesson, attempt: attempt.id), notice: notice
      else
        redirect_to training_course_lesson_path(@course, @lesson, attempt: attempt.id),
          alert: "You scored #{attempt.score}% — you need #{@course.pass_mark}% to pass. Read the feedback, then try again."
      end
    end

    # Heartbeat from the video player (training_video_controller.js).
    def video_progress
      unless @lesson.watch_required?
        render json: { watched: 0, complete: true }
        return
      end

      # An admin's preview is trusted for the video's real length; learners'
      # reports never are once it's known (TrainingLesson#known_video_duration).
      @lesson.learn_video_duration!(params[:duration]) if current_user.global_admin?

      view = @enrollment.video_view_for(@lesson)
      view.record_heartbeat!(position: params[:position])
      render json: { watched: view.watched_seconds, complete: @enrollment.video_watched?(@lesson) }
    end

    private

    def require_enrollment
      return if @enrollment

      redirect_to training_course_path(@course), alert: "Start the course to open its lessons."
    end

    def set_lesson
      @lesson = @course.lessons.find { |lesson| lesson.id == params[:id] } || raise(ActiveRecord::RecordNotFound)
      @lesson_index = @course.lessons.index(@lesson)
    end

    def require_unlocked
      return if @enrollment.lesson_unlocked?(@lesson)

      redirect_to training_course_lesson_path(@course, @enrollment.next_lesson),
        alert: "Finish this lesson first — lessons open in order."
    end

    def require_video_watched
      return if @enrollment.video_watched?(@lesson)

      redirect_to training_course_lesson_path(@course, @lesson), alert: "Watch the whole video first."
    end
  end
end
