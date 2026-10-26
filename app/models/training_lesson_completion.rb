class TrainingLessonCompletion < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :enrollment, class_name: "TrainingEnrollment", foreign_key: :training_enrollment_id
  belongs_to :lesson, class_name: "TrainingLesson", foreign_key: :training_lesson_id

  validates :training_lesson_id, uniqueness: { scope: :training_enrollment_id }
end
