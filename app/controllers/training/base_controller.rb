module Training
  class BaseController < ApplicationController
    include RestrictsBannedUsers

    before_action :require_sign_in

    private

    # Volunteers often have no Hack Club account, so signed-out visitors go to
    # a page offering both Hack Club Auth and an emailed code, and come back
    # to the page they asked for.
    def require_sign_in
      return if user_signed_in?

      session[:training_return_to] = request.fullpath if request.get? || request.head?
      redirect_to training_sign_in_path
    end

    def training_access
      @training_access ||= TrainingAccess.new(current_user)
    end

    # Global admins can open draft courses too, to check them before they go
    # out; completing a draft awards nothing (TrainingEnrollment#award_badge!).
    def visible_courses
      current_user.global_admin? ? TrainingCourse.where.not(status: :archived) : TrainingCourse.published
    end

    # Every course and lesson action goes through here, so an invite-only
    # course can't be started, continued or finished without access.
    def set_course
      @course = visible_courses.includes(*course_preloads).find_by!(slug: params[:course_slug] || params[:slug])

      unless training_access.accessible?(@course)
        render "training/courses/not_invited", status: :forbidden
        return
      end

      # A "yes" declaration the Hack Club Safety Team hasn't cleared stops all
      # training, with a neutral message rather than the word "ineligible".
      unless current_user.eligible_to_work_events?
        render "training/disclosures/under_review", status: :forbidden
        return
      end

      @enrollment = current_user.training_enrollments.find_by(course: @course)
      # Share the loaded course rather than fetching it again.
      @enrollment.course = @course if @enrollment
    end

    def course_preloads
      [ :badge, { lessons: { questions: :options } } ]
    end
  end
end
