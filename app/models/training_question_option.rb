class TrainingQuestionOption < ApplicationRecord
  include TrainingPositioned

  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :question, class_name: "TrainingQuestion", foreign_key: :training_question_id, inverse_of: :options

  validates :body, presence: true

  private

  def siblings
    TrainingQuestionOption.where(training_question_id: training_question_id)
  end
end
