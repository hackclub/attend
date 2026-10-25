require "rails_helper"

RSpec.describe "Training declarations", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:learner) { create(:user) }
  let(:course) { create(:training_course, :published, disclosure_required: true, access: "open") }
  let(:first_lesson) { course.lessons.first }

  before { sign_in learner }

  it "asks before the first lesson, and lets a no carry on" do
    post enroll_training_course_path(course)
    expect(response).to redirect_to(new_training_course_disclosure_path(course))

    get training_course_lesson_path(course, first_lesson)
    expect(response).to redirect_to(new_training_course_disclosure_path(course))

    get new_training_course_disclosure_path(course)
    expect(response.body).to include("have you been convicted of any of the following")

    post training_course_disclosure_path(course), params: { answer: "no", confirm: "1" }
    expect(response).to redirect_to(training_course_lesson_path(course, first_lesson))
    expect(learner.training_disclosures.last).to be_review_not_required
  end

  it "needs an answer and the confirmation" do
    post enroll_training_course_path(course)
    expect {
      post training_course_disclosure_path(course), params: { answer: "no" }
    }.not_to change(TrainingDisclosure, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "stops all training after a yes, tells the Safety Team, and stays neutral" do
    other = create(:training_course, :published, access: "open")
    post enroll_training_course_path(course)

    expect {
      post training_course_disclosure_path(course), params: { answer: "yes", confirm: "1" }
    }.to have_enqueued_mail(TrainingMailer, :disclosure_review_needed)
    expect(response.body).to include("Thanks for telling us", TrainingDisclosure::SAFETY_TEAM_EMAIL)
    expect(response.body).not_to match(/ineligible/i)

    get training_path
    expect(response.body).to include("Thanks for telling us")
    get training_course_path(other)
    expect(response).to have_http_status(:forbidden)
    get training_course_lesson_path(course, first_lesson)
    expect(response).to have_http_status(:forbidden)
  end

  it "uses the course's own wording, and keeps a copy of what was asked" do
    course.update!(disclosure_question: "Example custom declaration wording?")
    post enroll_training_course_path(course)
    post training_course_disclosure_path(course), params: { answer: "no", confirm: "1" }
    expect(learner.training_disclosures.last.question).to eq("Example custom declaration wording?")
  end

  describe "on the event staff page" do
    let(:event) { create(:event) }
    let(:admin) { create(:user, global_role: "global_admin") }

    it "flags someone ineligible without saying why" do
      create(:event_role_assignment, event: event, user: learner, role: "ops")
      learner.training_disclosures.create!(course: course, question: "Example declaration?", answer: "yes")

      sign_in admin
      get select_admin_event_path(slug: event.slug)
      get admin_event_staff_index_path(event_slug: event.slug)
      expect(response.body).to include("not eligible to work this event")
      row = response.body[/#{Regexp.escape(learner.email)}.*?<\/tr>/m]
      expect(row).to include("Ineligible")
      expect(row).not_to include("Not trained")
      expect(response.body).not_to include("Example declaration?")
    end
  end
end
