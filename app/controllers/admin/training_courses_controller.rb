module Admin
  class TrainingCoursesController < BaseController
    include AdminTrainingAuthoring

    before_action :set_course, except: [ :index, :new, :create ]

    def index
      @courses = TrainingCourse.ordered.includes(:badge, lessons: :questions)
      @pending_disclosures = TrainingDisclosure.review_pending.count
      @badges = TrainingBadge.ordered
      @holder_counts = TrainingBadgeAward.current.group(:training_badge_id).distinct.count(:user_id)
      @enrollment_counts = TrainingEnrollment.group(:training_course_id).count
      @completion_counts = TrainingEnrollment.where.not(completed_at: nil).group(:training_course_id).count
    end

    def show
      @lessons = @course.lessons.includes(questions: :options)
      @enrollments = @course.enrollments.includes(:user).order(started_at: :desc)
      @invitations = @course.invitations.includes(:user, :invited_by).order("users.email")
      @completed_counts = TrainingLessonCompletion.where(training_enrollment_id: @enrollments.map(&:id))
        .group(:training_enrollment_id).count
    end

    def new
      @course = TrainingCourse.new(badge: TrainingBadge.ordered.first)
    end

    def create
      @course = TrainingCourse.new(course_params.except(:status))

      if @course.save
        redirect_to admin_training_course_path(@course), notice: "Course created. Add its first lesson."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @course.update(course_params)
        notice = @course.saved_change_to_status? ? "Course #{@course.status}." : "Course updated."
        redirect_to admin_training_course_path(@course), notice: notice
      elsif course_params.keys == [ "status" ]
        redirect_to admin_training_course_path(@course), alert: @course.errors.full_messages.to_sentence
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # Once anyone has started a course their progress hangs off it, so it can
    # only be archived (hidden from learners, kept for the record) from then on.
    def destroy
      if @course.enrollments.exists?
        redirect_to admin_training_course_path(@course), alert: "People have started this course, so it can't be deleted. Archive it instead."
        return
      end

      @course.destroy
      redirect_to admin_training_path, notice: "Course deleted."
    end

    def move
      move_redirect(@course, admin_training_path)
    end

    private

    def course_params
      params.require(:training_course).permit(:title, :slug, :summary, :training_badge_id, :pass_mark, :estimated_minutes, :status, :access, :reveal_answers, :disclosure_required, :disclosure_question)
    end
  end
end
