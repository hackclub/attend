require "rails_helper"

RSpec.describe "Training", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:learner) { create(:user) }
  let(:course) { create(:training_course, :published) }
  let(:reading) { course.lessons.first }
  let(:quiz) { course.lessons.second }
  let(:question) { quiz.questions.first }
  let(:right) { question.options.find(&:correct?) }
  let(:wrong) { question.options.reject(&:correct?).first }

  before do
    sign_in learner
    TrainingCourseInvitation.create!(course: course, user: learner)
  end

  def enroll
    post enroll_training_course_path(course)
    learner.training_enrollments.find_by!(course: course)
  end

  it "lists published courses but hides drafts from learners" do
    draft = create(:training_course, :with_lessons, title: "Unfinished Course")
    TrainingCourseInvitation.create!(course: draft, user: learner)
    get training_path

    expect(response.body).to include(course.title)
    expect(response.body).not_to include(draft.title)
    get training_course_path(draft)
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to include("could not be found")
  end

  it "keeps later lessons locked until earlier ones are done" do
    enroll
    get training_course_lesson_path(course, quiz)
    expect(response).to redirect_to(training_course_lesson_path(course, reading))
  end

  it "rejects a quiz with an unanswered question without counting an attempt" do
    enroll.complete_lesson!(reading)

    expect {
      post quiz_training_course_lesson_path(course, quiz), params: { answers: {} }
    }.not_to change(TrainingQuizAttempt, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Answer every question")
  end

  it "explains a wrong pick without revealing the right answer until a pass" do
    enroll.complete_lesson!(reading)

    post quiz_training_course_lesson_path(course, quiz), params: { answers: { question.id => [ wrong.id ] } }
    follow_redirect!

    expect(response.body).to include("Not passed yet")
    expect(response.body).to include("No — this is why not.")
    expect(response.body).not_to include("Yes — this is why.")
    expect(response.body).not_to include("correct answer</span>")
  end

  it "reveals answers on every attempt when the course allows it" do
    course.update!(reveal_answers: "every_attempt")
    enroll.complete_lesson!(reading)

    post quiz_training_course_lesson_path(course, quiz), params: { answers: { question.id => [ wrong.id ] } }
    follow_redirect!
    expect(response.body).to include("Yes — this is why.")
    expect(response.body).to include("Because it is.")
  end

  it "awards the badge on passing and shows the full review" do
    enroll.complete_lesson!(reading)

    expect {
      post quiz_training_course_lesson_path(course, quiz), params: { answers: { question.id => [ right.id ] } }
    }.to change { learner.training_badge_awards.count }.by(1)
    follow_redirect!

    expect(response.body).to include("You passed")
    expect(response.body).to include("Yes — this is why.")
    expect(response.body).to include("View your badge")
  end

  describe "a lesson with a video that must be watched" do
    before { reading.update!(video_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", video_duration_seconds: 20) }

    it "won't mark the lesson done until the video is watched" do
      enroll
      post complete_training_course_lesson_path(course, reading)
      expect(response).to redirect_to(training_course_lesson_path(course, reading))
      expect(flash[:alert]).to include("Watch the whole video")
    end

    it "takes progress heartbeats and opens once the end is reached in real time" do
      enrollment = enroll
      start = Time.current

      travel_to(start) { post video_progress_training_course_lesson_path(course, reading), params: { position: 0, duration: 20 }, as: :json }
      travel_to(start + 1.second) { post video_progress_training_course_lesson_path(course, reading), params: { position: 20, duration: 20 }, as: :json }
      expect(response.parsed_body["complete"]).to be(false)

      travel_to(start + 20.seconds) { post video_progress_training_course_lesson_path(course, reading), params: { position: 20, duration: 20 }, as: :json }
      expect(response.parsed_body["complete"]).to be(true)

      post complete_training_course_lesson_path(course, reading)
      expect(enrollment.reload.lesson_completed?(reading)).to be(true)
    end

    it "learns the real length from a global admin's preview, not a learner's" do
      reading.update!(video_duration_seconds: nil)
      enroll
      post video_progress_training_course_lesson_path(course, reading), params: { position: 0, duration: 3 }, as: :json
      expect(reading.reload.video_duration_seconds).to be_nil

      admin = create(:user, global_role: "global_admin")
      sign_in admin
      post enroll_training_course_path(course)
      post video_progress_training_course_lesson_path(course, reading), params: { position: 0, duration: 212.5 }, as: :json
      expect(reading.reload.video_duration_seconds).to eq(212.5)
    end

    it "tells learners when the video isn't ready yet" do
      reading.update!(video_duration_seconds: nil)
      enroll
      get training_course_lesson_path(course, reading)
      expect(response.body).to include("This video isn't ready yet")
    end

    it "renders the gated player" do
      enroll
      get training_course_lesson_path(course, reading)
      expect(response.body).to include('data-controller="training-video"')
      expect(response.body).to include("you can rewind, but not skip ahead")
    end
  end

  it "only shows someone their own badges" do
    award = create(:training_badge_award)
    get training_award_path(award)
    expect(response).to redirect_to(root_path)
  end

  it "renders lesson markdown without letting scripts through" do
    reading.update!(body: "**bold**\n\n<script>alert(1)</script>")
    enroll
    get training_course_lesson_path(course, reading)
    expect(response.body).to include("<strong>bold</strong>")
    expect(response.body).not_to include("<script>alert(1)")
  end

  describe "invite-only courses" do
    let(:other) { create(:training_course, :published, title: "Example Invite-only Course") }

    it "hides a course nobody invited them to, and refuses to open it" do
      other
      get training_path
      expect(response.body).not_to include(other.title)

      get training_course_path(other)
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("is invite-only")

      expect { post enroll_training_course_path(other) }.not_to change(TrainingEnrollment, :count)
    end

    it "opens to staff whose role at an upcoming event needs the badge it awards" do
      other.badge.update!(required_roles: %w[ops])
      event = create(:event, starts_at: 1.week.from_now, ends_at: 8.days.from_now)
      create(:event_role_assignment, event: event, user: learner, role: "ops")

      get training_course_path(other)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Required for your role at #{event.name}")
    end

    it "doesn't open through an event that has finished" do
      other.badge.update!(required_roles: %w[volunteer])
      event = create(:event, starts_at: 2.weeks.ago, ends_at: 13.days.ago)
      create(:event_volunteer, event: event, user: learner)

      get training_course_path(other)
      expect(response).to have_http_status(:forbidden)
    end

    it "lets anyone into an open course" do
      other.update!(access: "open")
      get training_course_path(other)
      expect(response).to have_http_status(:ok)
    end

    it "stops a learner mid-course once their invitation is removed" do
      enroll
      learner.training_course_invitations.destroy_all

      get training_course_lesson_path(course, reading)
      expect(response).to have_http_status(:forbidden)
      post complete_training_course_lesson_path(course, reading)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
