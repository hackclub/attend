require "rails_helper"

RSpec.describe "Training declarations", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:learner) { create(:user) }
  let(:course) { create(:training_course, :published, disclosure_required: true, access: "open") }
  let(:first_lesson) { course.lessons.first }

  before do
    create(:training_profile, user: learner)
    sign_in learner
  end

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
    post training_course_disclosure_path(course), params: { answer: "yes", confirm: "1" }

    expect {
      post confirm_training_course_disclosure_path(course)
    }.to have_enqueued_mail(TrainingMailer, :disclosure_review_needed)
    expect(response).to redirect_to(training_path)
    follow_redirect!
    expect(response.body).to include("Thanks for telling us", TrainingDisclosure::SAFETY_TEAM_EMAIL)
    expect(response.body).not_to match(/ineligible/i)

    get training_course_path(other)
    expect(response).to have_http_status(:forbidden)
    get training_course_lesson_path(course, first_lesson)
    expect(response).to have_http_status(:forbidden)
  end

  it "checks a yes before recording it, so a stray tap can be undone" do
    post enroll_training_course_path(course)

    expect {
      post training_course_disclosure_path(course), params: { answer: "yes", confirm: "1" }
    }.not_to change(TrainingDisclosure, :count)
    expect(response).to redirect_to(confirm_training_course_disclosure_path(course))
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Check your answer", "No, change my answer")
    expect(response.body).not_to include("Thanks for telling us")
    # The way out is the first, prominent button; confirming is the quiet one.
    expect(response.body).to match(/portal-btn-primary[^>]*>No, change my answer.*portal-btn-secondary[^>]*>\s*Yes, that/m)

    get new_training_course_disclosure_path(course)
    expect(response).to have_http_status(:ok)
    post training_course_disclosure_path(course), params: { answer: "no", confirm: "1" }
    expect(response).to redirect_to(training_course_lesson_path(course, first_lesson))
    expect(learner.training_disclosures.last).to be_review_not_required
  end

  it "only records a yes that came through the form and its confirmation" do
    post enroll_training_course_path(course)

    # Straight to the second step, or with the old hidden-field flag.
    expect {
      post confirm_training_course_disclosure_path(course)
      post training_course_disclosure_path(course), params: { answer: "yes", yes_confirmed: "1" }
    }.not_to change(TrainingDisclosure, :count)

    get confirm_training_course_disclosure_path(course)
    expect(response).to redirect_to(new_training_course_disclosure_path(course))
  end

  it "drops a yes that was waiting to be checked once they go back to the form" do
    post enroll_training_course_path(course)
    post training_course_disclosure_path(course), params: { answer: "yes", confirm: "1" }
    get new_training_course_disclosure_path(course)

    expect {
      post confirm_training_course_disclosure_path(course)
    }.not_to change(TrainingDisclosure, :count)
    expect(response).to redirect_to(new_training_course_disclosure_path(course))
  end

  it "won't record a second answer once the declaration is made" do
    post enroll_training_course_path(course)
    # A yes left on the "check your answer" page in one tab...
    post training_course_disclosure_path(course), params: { answer: "yes", confirm: "1" }
    # ...while a form already open in another tab answers no.
    post training_course_disclosure_path(course), params: { answer: "no", confirm: "1" }

    expect {
      post confirm_training_course_disclosure_path(course)
    }.not_to change(TrainingDisclosure, :count)
    expect(response).to redirect_to(training_course_path(course))
    expect(learner.reload).to be_eligible_to_work_events

    get new_training_course_disclosure_path(course)
    expect(response).to redirect_to(training_course_path(course))
  end

  it "records one declaration when the confirm button is tapped twice" do
    post enroll_training_course_path(course)
    post training_course_disclosure_path(course), params: { answer: "yes", confirm: "1" }

    # The other tap saves after this request's checks but before its lock.
    allow_any_instance_of(TrainingEnrollment).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      enrollment = original.receiver
      enrollment.user.training_disclosures.create!(course: course, enrollment: enrollment, question: "Example declaration?", answer: "yes")
      original.call(*args, &block)
    end

    expect {
      expect {
        post confirm_training_course_disclosure_path(course)
      }.to change(TrainingDisclosure, :count).by(1)
    }.not_to have_enqueued_mail(TrainingMailer, :disclosure_review_needed)
    expect(response).to redirect_to(training_path)
  end

  it "doesn't take a declaration for a course that doesn't ask for one" do
    course.update!(disclosure_required: false)
    post enroll_training_course_path(course)

    expect {
      post training_course_disclosure_path(course), params: { answer: "yes", confirm: "1" }
      post confirm_training_course_disclosure_path(course)
    }.not_to change(TrainingDisclosure, :count)
    expect(response).to redirect_to(training_course_path(course))
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

    it "doesn't show staff who aren't event admins who is ineligible" do
      create(:event_role_assignment, event: event, user: learner, role: "ops")
      learner.training_disclosures.create!(course: course, question: "Example declaration?", answer: "yes")
      colleague = create(:event_role_assignment, event: event, role: "limited").user

      sign_in colleague
      get select_admin_event_path(slug: event.slug)
      get admin_event_staff_index_path(event_slug: event.slug)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(learner.email)
      expect(response.body).not_to include("Ineligible", "not eligible to work this event")
    end
  end
end
