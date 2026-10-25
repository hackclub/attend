module Training
  class CoursesController < BaseController
    before_action :set_course, except: :index

    def index
      return render("training/disclosures/under_review") unless current_user.eligible_to_work_events?

      @courses = training_access.courses(visible_courses).ordered.includes(:badge, :lessons)
      @enrollments = current_user.training_enrollments.index_by(&:training_course_id)
      @awards = current_user.training_badge_awards.includes(:course, badge: { image_attachment: :blob }).newest_first
      @requirements = upcoming_requirements
    end

    def show
      @award = current_user.training_badge_awards.includes(:badge).current
        .where(training_badge_id: @course.training_badge_id).order(:expires_at).last if @course.badge
    end

    def enroll
      enrollment = current_user.training_enrollments.find_or_create_by!(course: @course)
      if enrollment.disclosure_needed?
        redirect_to new_training_course_disclosure_path(@course)
      else
        redirect_to training_course_lesson_path(@course, enrollment.next_lesson || @course.lessons.first)
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def restart
      if @enrollment.nil?
        redirect_to training_course_path(@course)
        return
      end

      @enrollment.restart!
      next_step = @enrollment.disclosure_needed? ? new_training_course_disclosure_path(@course) : training_course_lesson_path(@course, @course.lessons.first)
      redirect_to next_step, notice: "Course restarted. Your badge stays valid until it expires."
    end

    private

    # Badges this person still needs for an event they're working that hasn't
    # finished, so the page can say what's required and by when.
    def upcoming_requirements
      event_ids = current_user.event_role_assignments.pluck(:event_id) + current_user.event_volunteers.pluck(:event_id)
      series_ids = current_user.series_role_assignments.select(:event_series_id)
      events = Event.where(id: event_ids.uniq).or(Event.where(event_series_id: series_ids))
        .where("events.ends_at IS NULL OR events.ends_at >= ?", Time.current)
        .order(:starts_at)

      events.filter_map do |event|
        status = TrainingStatus.for_user_at_event(current_user, event)
        [ event, status ] if status.missing.any? || status.expiring.any?
      end
    end
  end
end
