module Training
  class BaseController < ApplicationController
    include RestrictsBannedUsers

    before_action :authenticate_user!

    private

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
      @course = visible_courses.includes(:badge, lessons: { questions: :options }).find_by!(slug: params[:course_slug] || params[:slug])

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
    end
  end
end
