class TrainingQuizAttempt < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :enrollment, class_name: "TrainingEnrollment", foreign_key: :training_enrollment_id
  belongs_to :lesson, class_name: "TrainingLesson", foreign_key: :training_lesson_id

  # Marks a submission against the lesson's questions. `answers` maps a
  # question id to the option id(s) chosen; anything unanswered is wrong.
  # Scored as the share of questions answered exactly right.
  def self.grade(enrollment:, lesson:, answers:)
    answers = answers.to_h.transform_keys(&:to_s)
    questions = lesson.questions.includes(:options).to_a
    responses = questions.to_h { |q| [ q.id, Array(answers[q.id]).compact_blank.map(&:to_s) ] }
    right = questions.count { |q| q.correct?(responses[q.id]) }
    score = questions.empty? ? 100 : ((right.to_f / questions.size) * 100).round

    create!(
      enrollment: enrollment,
      lesson: lesson,
      responses: responses,
      score: score,
      passed: score >= enrollment.course.pass_mark
    )
  end

  def answered_correctly?(question)
    question.correct?(responses[question.id])
  end

  def chosen?(question, option)
    Array(responses[question.id]).include?(option.id)
  end
end
