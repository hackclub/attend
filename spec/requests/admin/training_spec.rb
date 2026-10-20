require "rails_helper"

RSpec.describe "Admin training", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }

  before { sign_in admin }

  [ true, false ].each do |console|
    context(console ? "in the admin console" : "in the original admin") do
      before { admin.update!(admin_console_beta: console) }

      it "renders every authoring page" do
        course = create(:training_course, :with_lessons)
        lesson = course.lessons.second
        question = lesson.questions.first
        create(:training_badge_award, badge: course.badge)

        [
          admin_training_path,
          new_admin_training_course_path,
          admin_training_course_path(course),
          edit_admin_training_course_path(course),
          new_admin_training_course_lesson_path(course),
          edit_admin_training_course_lesson_path(course, lesson),
          new_admin_training_course_lesson_question_path(course, lesson),
          edit_admin_training_course_lesson_question_path(course, lesson, question),
          new_admin_training_badge_path,
          admin_training_badge_path(course.badge),
          edit_admin_training_badge_path(course.badge),
          new_admin_training_badge_award_path(course.badge)
        ].each do |path|
          get path
          expect(response).to have_http_status(:ok), "#{path} returned #{response.status}"
        end
      end
    end
  end

  it "builds a course: badge, course, lesson, question with reasons, publish" do
    post admin_training_badges_path, params: { training_badge: { name: "Example Event Badge", validity_months: 24, required_roles: [ "", "ops", "volunteer" ] } }
    badge = TrainingBadge.last
    expect(badge.required_roles).to eq(%w[ops volunteer])

    post admin_training_courses_path, params: { training_course: { title: "Example Safety Course", training_badge_id: badge.id, pass_mark: 75 } }
    course = TrainingCourse.last
    expect(response).to redirect_to(admin_training_course_path(course))

    post admin_training_course_lessons_path(course), params: { training_lesson: { title: "Spotting concerns", body: "Read this.", video_url: "https://vimeo.com/123456", require_full_watch: "1", video_duration_seconds: "95" } }
    lesson = course.lessons.last
    expect(lesson.video_source).to eq(:vimeo)

    post admin_training_course_lesson_questions_path(course, lesson), params: {
      training_question: {
        prompt: "Who do you tell?",
        options_attributes: {
          "0" => { body: "The safeguarding lead", correct: "1", explanation: "They own every concern." },
          "1" => { body: "Nobody", correct: "0", explanation: "Concerns must always be shared." },
          "2" => { body: "", correct: "0" }
        }
      }
    }
    question = lesson.questions.last
    expect(question.options.map(&:explanation)).to eq([ "They own every concern.", "Concerns must always be shared." ])

    patch admin_training_course_path(course), params: { training_course: { status: "published" } }
    expect(course.reload).to be_published
  end

  it "rejects a video link from a player that can't stop skipping" do
    course = create(:training_course)
    post admin_training_course_lessons_path(course), params: { training_lesson: { title: "Video", video_url: "https://www.loom.com/share/abc123" } }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "awards and revokes a badge by hand" do
    badge = create(:training_badge)
    post admin_training_badge_awards_path(badge), params: {
      email: "volunteer-example@example.com",
      training_badge_award: { note: "Equivalent certificate from another org", awarded_at: Date.current }
    }
    award = badge.awards.last
    expect(award.user.email).to eq("volunteer-example@example.com")
    expect(award.awarded_by).to eq(admin)

    patch revoke_admin_training_badge_award_path(badge, award), params: { reason: "Issued in error" }
    expect(award.reload).to be_revoked
    expect(award.revoked_reason).to eq("Issued in error")
  end

  it "is closed to anyone but global admins" do
    event = create(:event)
    staff = create(:event_role_assignment, event: event, role: "event_admin").user
    sign_in staff

    get admin_training_path
    expect(response).to redirect_to(admin_root_path)
  end

  describe "invitations" do
    let(:course) { create(:training_course, :published) }

    it "invites a pasted list by email, skipping duplicates and bad addresses" do
      create(:user, email: "already-here@example.com").then { |user| course.invitations.create!(user: user) }

      expect {
        post admin_training_course_invitations_path(course), params: {
          emails: "first-invitee@example.com, already-here@example.com\nnot-an-email\nSECOND-invitee@example.com"
        }
      }.to change(TrainingCourseInvitation, :count).by(2)
        .and have_enqueued_mail(TrainingMailer, :course_invitation).twice

      expect(course.invitations.joins(:user).pluck("users.email")).to include("first-invitee@example.com", "second-invitee@example.com")
      expect(flash[:notice]).to include("2 people invited", "1 was already invited", "Skipped: not-an-email")
    end

    it "holds invitation emails for a draft course" do
      draft = create(:training_course)
      expect {
        post admin_training_course_invitations_path(draft), params: { emails: "draft-invitee@example.com" }
      }.not_to have_enqueued_mail(TrainingMailer, :course_invitation)
      expect(draft.invitations.count).to eq(1)
    end

    it "removes an invitation" do
      invitation = course.invitations.create!(user: create(:user))
      expect {
        delete admin_training_course_invitation_path(course, invitation)
      }.to change(TrainingCourseInvitation, :count).by(-1)
    end

    it "saves the access and answer-reveal settings" do
      patch admin_training_course_path(course), params: { training_course: { access: "open", reveal_answers: "every_attempt" } }
      expect(course.reload).to be_access_open
      expect(course).to be_reveal_answers_every_attempt
    end
  end
end
