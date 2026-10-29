# Shared by the /admin/training controllers: courses, badges and awards are
# org-wide, so only global admins author them.
module AdminTrainingAuthoring
  extend ActiveSupport::Concern

  included do
    global_page
    before_action :require_global_admin
  end

  private

  def require_global_admin
    return if current_user.global_admin?

    redirect_to admin_root_path, alert: "Only global admins can manage training."
  end

  def set_course
    @course = TrainingCourse.find_by!(slug: params[:course_slug] || params[:slug])
    @record = @course
  end

  def move_redirect(record, fallback)
    record.move!(params[:direction])
    redirect_back_or_to fallback
  end
end
