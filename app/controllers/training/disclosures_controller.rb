module Training
  # The criminal-record declaration a course can ask before its first lesson
  # (TrainingCourse#disclosure_required). A yes makes the person ineligible
  # until the Hack Club Safety Team reviews it.
  class DisclosuresController < BaseController
    before_action :set_course
    before_action :require_enrollment
    before_action :require_disclosure_needed

    def new
    end

    def create
      answer = params[:answer].to_s
      unless %w[yes no].include?(answer) && params[:confirm] == "1"
        flash.now[:alert] = "Choose yes or no, and confirm your answer is true."
        render :new, status: :unprocessable_entity
        return
      end

      # A yes locks the person out of all training until the Safety Team
      # reviews it, so a stray tap mustn't be enough: ask them to check it
      # before anything is recorded.
      if answer == "yes" && params[:yes_confirmed] != "1"
        render :confirm_yes
        return
      end

      disclosure = current_user.training_disclosures.create!(
        course: @course,
        enrollment: @enrollment,
        question: @course.disclosure_question_text,
        answer: answer
      )

      if disclosure.answered_yes?
        TrainingMailer.disclosure_review_needed(disclosure: disclosure).deliver_later
        render "training/disclosures/under_review"
      else
        redirect_to training_course_lesson_path(@course, @enrollment.next_lesson || @course.lessons.first)
      end
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
  end
end
