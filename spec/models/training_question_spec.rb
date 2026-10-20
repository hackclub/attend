require "rails_helper"

RSpec.describe TrainingQuestion do
  it "needs a correct answer among at least two" do
    question = build(:training_question)
    question.options.each { |option| option.correct = false }
    expect(question).not_to be_valid

    question.options = [ TrainingQuestionOption.new(body: "Only", correct: true) ]
    expect(question).not_to be_valid
  end

  it "requires exactly the right set when several answers are correct" do
    question = build(:training_question)
    question.options.build(body: "Also right", correct: true)
    question.save!
    right_ids = question.options.select(&:correct?).map(&:id)

    expect(question).to be_multiple_answers
    expect(question.correct?(right_ids)).to be(true)
    expect(question.correct?(right_ids.first(1))).to be(false)
    expect(question.correct?(question.options.map(&:id))).to be(false)
  end

  it "won't let a course publish while a question has no right answer" do
    course = create(:training_course, :with_lessons)
    course.lessons.second.questions.first.options.update_all(correct: false)
    expect(course.reload.update(status: "published")).to be(false)
    expect(course.errors[:status].join).to include("no correct answer")
  end
end
