module Training
  # The criminal-record declaration a course can ask before its first lesson
  # (TrainingCourse#disclosure_required). A yes makes the person ineligible
  # until the Hack Club Safety Team reviews it.
  class DisclosuresController < BaseController
    before_action :set_course
    before_action :require_enrollment
    before_action :require_disclosure_needed
    before_action :require_pending_yes, only: %i[confirm_yes record_yes]

    # Set when the form is submitted with a yes, so the "check your answer"
    # step is held here rather than in fields the page sends back.
    PENDING_YES_KEY = :training_disclosure_pending_yes

    def new
      # Back on the form, a yes that was waiting to be checked is dropped.
      session.delete(PENDING_YES_KEY)
    end

    def create
      answer = params[:answer].to_s
      unless %w[yes no].include?(answer) && params[:confirm] == "1"
        flash.now[:alert] = "Choose yes or no, and confirm your answer is true."
        render :new, status: :unprocessable_entity
        return
      end

      # A yes locks the person out of all training until the Safety Team
      # reviews it, so a stray tap mustn't be enough: nothing is recorded
      # until they've checked it on the next page.
      if answer == "yes"
        session[PENDING_YES_KEY] = pending_yes_token
        redirect_to confirm_training_course_disclosure_path(@course)
        return
      end

      session.delete(PENDING_YES_KEY)
      record!("no")
      redirect_to training_course_lesson_path(@course, @enrollment.next_lesson || @course.lessons.first)
    end

    def confirm_yes
    end

    # The only place a yes is recorded, and only for someone who came through
    # the form (and its "my answer is true" tick) for this attempt.
    def record_yes
      session.delete(PENDING_YES_KEY)
      disclosure = record!("yes")
      TrainingMailer.disclosure_review_needed(disclosure: disclosure).deliver_later if disclosure
      # The training home shows the neutral "thanks for telling us" page to
      # anyone waiting on a review, and a refresh there re-sends nothing.
      redirect_to training_path
    end

    private

    def require_enrollment
      return if @enrollment

      redirect_to training_course_path(@course)
    end

    # Once this attempt at the course has its answer (or the course doesn't
    # ask), nothing here may record another: a "check your answer" page left
    # open in another tab would otherwise still lock the person out.
    def require_disclosure_needed
      return if @enrollment.disclosure_needed?

      redirect_to training_course_path(@course)
    end

    def require_pending_yes
      return if session[PENDING_YES_KEY] == pending_yes_token

      redirect_to new_training_course_disclosure_path(@course)
    end

    # Names this attempt at the course: a restart asks the question afresh.
    def pending_yes_token
      "#{@enrollment.id}:#{@enrollment.started_at.to_i}"
    end

    # Records the answer once per attempt. Two taps on a slow connection both
    # get past require_disclosure_needed before either saves, so the check is
    # made again under a lock on the enrollment; the loser records nothing
    # and returns nil.
    def record!(answer)
      @enrollment.with_lock do
        next unless @enrollment.disclosure_needed?

        current_user.training_disclosures.create!(
          course: @course,
          enrollment: @enrollment,
          question: @course.disclosure_question_text,
          answer: answer
        )
      end
    end
  end
end
