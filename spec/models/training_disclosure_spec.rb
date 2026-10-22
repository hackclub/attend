require "rails_helper"

RSpec.describe TrainingDisclosure do
  let(:user) { create(:user) }
  let(:course) { create(:training_course, :published, disclosure_required: true) }

  def declare(answer, enrollment: nil)
    user.training_disclosures.create!(course: course, enrollment: enrollment, question: course.disclosure_question_text, answer: answer)
  end

  it "needs no review for a no, and makes someone ineligible for a yes" do
    expect(declare("no")).to be_review_not_required
    expect(user).to be_eligible_to_work_events

    expect(declare("yes")).to be_review_pending
    expect(user).not_to be_eligible_to_work_events
  end

  it "keeps the answer and review note out of plain sight" do
    disclosure = declare("yes")
    raw = TrainingDisclosure.connection.select_one("SELECT answer FROM training_disclosures WHERE id = #{TrainingDisclosure.connection.quote(disclosure.id)}")
    expect(raw["answer"]).not_to eq("yes")
  end

  it "restores eligibility when cleared, and needs a note to review" do
    disclosure = declare("yes")
    expect { disclosure.review!(outcome: "cleared", by: create(:user), note: "") }.to raise_error(ActiveRecord::RecordInvalid)

    disclosure.review!(outcome: "cleared", by: create(:user), note: "Reviewed with the person; not relevant to this role.")
    expect(user).to be_eligible_to_work_events

    declare("yes").review!(outcome: "upheld", by: create(:user), note: "Not suitable.")
    expect(user).not_to be_eligible_to_work_events
  end

  it "is asked again on each attempt at the course" do
    enrollment = create(:training_enrollment, user: user, course: course)
    expect(enrollment).to be_disclosure_needed

    declare("no", enrollment: enrollment)
    expect(enrollment.reload).not_to be_disclosure_needed

    enrollment.restart!
    expect(enrollment.reload).to be_disclosure_needed
  end

  it "stops an ineligible person earning a badge" do
    enrollment = create(:training_enrollment, user: user, course: course)
    declare("yes", enrollment: enrollment)

    course.lessons.each { |lesson| enrollment.complete_lesson!(lesson, score: 100) }
    expect(user.training_badge_awards).to be_empty
  end
end
