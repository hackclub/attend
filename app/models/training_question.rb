class TrainingQuestion < ApplicationRecord
  include TrainingPositioned

  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :lesson, class_name: "TrainingLesson", foreign_key: :training_lesson_id, inverse_of: :questions, touch: true
  has_many :options, -> { ordered }, class_name: "TrainingQuestionOption", dependent: :destroy, inverse_of: :question

  accepts_nested_attributes_for :options, allow_destroy: true,
    reject_if: ->(attrs) { attrs["body"].blank? && attrs["id"].blank? }

  validates :prompt, presence: true
  validate :options_are_markable

  # One right answer renders as radio buttons; more than one as checkboxes,
  # and the learner has to pick exactly the right set.
  def multiple_answers?
    live_options.count(&:correct?) > 1
  end

  def answerable?
    live_options.any?(&:correct?)
  end

  def correct_option_ids
    live_options.select(&:correct?).map(&:id).sort
  end

  def correct?(chosen_ids)
    Array(chosen_ids).compact_blank.map(&:to_s).sort == correct_option_ids.map(&:to_s)
  end

  private

  def live_options
    options.reject(&:marked_for_destruction?)
  end

  def siblings
    TrainingQuestion.where(training_lesson_id: training_lesson_id)
  end

  def options_are_markable
    if live_options.size < 2
      errors.add(:options, "need at least two answers to choose from")
    elsif !answerable?
      errors.add(:options, "need at least one marked correct")
    end
  end
end
