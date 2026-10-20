module Admin
  class TrainingLessonsController < BaseController
    include AdminTrainingAuthoring

    before_action :set_course
    before_action :set_lesson, except: [ :new, :create ]

    def new
      @lesson = @course.lessons.build
    end

    def create
      @lesson = @course.lessons.build(lesson_params)

      if @lesson.save
        redirect_to edit_admin_training_course_lesson_path(@course, @lesson), notice: "Lesson added. Add quiz questions below, or leave it as a reading."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if params.dig(:training_lesson, :remove_video_file) == "1"
        @lesson.video_file.purge_later
        @lesson.video_duration_seconds = nil
      end

      if @lesson.update(lesson_params)
        redirect_to edit_admin_training_course_lesson_path(@course, @lesson), notice: "Lesson saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @lesson.destroy
      redirect_to admin_training_course_path(@course), notice: "Lesson deleted."
    end

    def move
      move_redirect(@lesson, admin_training_course_path(@course))
    end

    private

    def set_lesson
      @lesson = @course.lessons.find(params[:id])
      @record = @lesson
    end

    def lesson_params
      params.require(:training_lesson).permit(:title, :body, :video_url, :video_file, :require_full_watch, :video_duration_seconds)
    end
  end
end
