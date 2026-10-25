module Admin
  class TrainingQuestionsController < BaseController
    include AdminTrainingAuthoring

    BLANK_OPTIONS = 4

    before_action :set_course
    before_action :set_lesson
    before_action :set_question, except: [ :new, :create ]

    def new
      @question = @lesson.questions.build
      BLANK_OPTIONS.times { @question.options.build }
    end

    def create
      @question = @lesson.questions.build(question_params)

      if @question.save
        redirect_to edit_admin_training_course_lesson_path(@course, @lesson), notice: "Question added."
      else
        pad_options
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      pad_options
    end

    def update
      if @question.update(question_params)
        redirect_to edit_admin_training_course_lesson_path(@course, @lesson), notice: "Question saved."
      else
        pad_options
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @question.destroy
      redirect_to edit_admin_training_course_lesson_path(@course, @lesson), notice: "Question deleted."
    end

    def move
      move_redirect(@question, edit_admin_training_course_lesson_path(@course, @lesson))
    end

    private

    def set_lesson
      @lesson = @course.lessons.find(params[:lesson_id])
    end

    def set_question
      @question = @lesson.questions.find(params[:id])
      @record = @question
    end

    # Always leave a couple of empty answer rows to type into.
    def pad_options
      blanks = [ 2, BLANK_OPTIONS - @question.options.size ].max
      blanks.times { @question.options.build }
    end

    def question_params
      params.require(:training_question).permit(:prompt, :explanation, options_attributes: [ :id, :body, :correct, :explanation, :_destroy ])
    end
  end
end
