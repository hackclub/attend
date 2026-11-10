require "rails_helper"

RSpec.describe "Signing in to training with an emailed code", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:event) { create(:event) }
  let(:volunteer) { create(:user, email: "volunteer@example.com") }
  let(:course) { create(:training_course, :published) }

  # The code and its attempt count live in Rails.cache, which is a null store
  # in tests.
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  before do
    # Whether Turnstile is configured depends on the local credentials.
    allow(TurnstileVerifier).to receive(:verify).and_return(true)
    allow(TurnstileVerifier).to receive(:site_key).and_return(nil)
    allow(SecureRandom).to receive(:random_number).and_call_original
    allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(123_456)
    create(:event_volunteer, event: event, user: volunteer)
    TrainingCourseInvitation.create!(course: course, user: volunteer)
  end

  def request_code(email)
    post training_sign_in_code_path, params: { email: email }
  end

  def sign_in_with_code(email, code: "123456")
    request_code(email)
    post training_sign_in_verify_path, params: { code: code }
  end

  it "sends signed-out visitors to the sign-in page and back to what they asked for" do
    get training_course_path(course)
    expect(response).to redirect_to(training_sign_in_path)

    get training_sign_in_path
    expect(response.body).to include("Continue with Hack Club", "Email me a code")

    sign_in_with_code("Volunteer@Example.com")
    expect(response).to redirect_to(training_course_path(course))
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(course.title)
  end

  it "emails a code to a volunteer without a Hack Club account" do
    expect { request_code("volunteer@example.com") }
      .to have_enqueued_mail(TrainingMailer, :sign_in_code)
    expect(response).to redirect_to(training_sign_in_verify_path)
  end

  it "keeps the code out of the subject line" do
    mail = TrainingMailer.sign_in_code(user: volunteer, code: "123456")
    expect(mail.subject).not_to include("123456")
    expect(mail.text_part.body.decoded).to include("123456")
  end

  {
    "someone Attend doesn't know" => -> { "stranger@example.com" },
    "a volunteer who has linked a Hack Club account" => -> { volunteer.update!(hack_club_account_id: "hca-example-1"); volunteer.email },
    "a volunteer who is also staff on an event" => -> { create(:event_role_assignment, user: volunteer, role: "read_only"); volunteer.email },
    "a volunteer who is a global admin" => -> { volunteer.update!(global_role: "global_admin"); volunteer.email },
    "a volunteer who is also a participant" => -> { create(:participant, email: volunteer.email); volunteer.email }
  }.each do |who, setup|
    it "sends no code to #{who}, and says the same thing" do
      email = instance_exec(&setup)
      expect { request_code(email) }.not_to have_enqueued_mail(TrainingMailer, :sign_in_code)
      expect(response).to redirect_to(training_sign_in_verify_path)
    end
  end

  it "keeps a code session to training" do
    sign_in_with_code(volunteer.email)

    get dashboard_path
    expect(response).to redirect_to(training_path)
    get admin_root_path
    expect(response).to redirect_to(training_path)
    get training_path
    expect(response).to have_http_status(:ok)
  end

  it "ends a code session once the person gets a role on an event" do
    sign_in_with_code(volunteer.email)
    create(:event_role_assignment, user: volunteer, event: event, role: "event_admin")

    get admin_root_path
    expect(response).to redirect_to(training_sign_in_path)
    get training_path
    expect(response).to redirect_to(training_sign_in_path)
  end

  it "rejects a wrong code, and gives up after too many" do
    request_code(volunteer.email)
    post training_sign_in_verify_path, params: { code: "000000" }
    expect(response).to redirect_to(training_sign_in_verify_path)

    5.times { post training_sign_in_verify_path, params: { code: "000000" } }
    post training_sign_in_verify_path, params: { code: "123456" }
    expect(response).to redirect_to(training_sign_in_path)
    get training_path
    expect(response).to redirect_to(training_sign_in_path)
  end

  it "rejects an expired code" do
    request_code(volunteer.email)
    travel 11.minutes do
      post training_sign_in_verify_path, params: { code: "123456" }
    end
    expect(response).to redirect_to(training_sign_in_path)
    get training_path
    expect(response).to redirect_to(training_sign_in_path)
  end

  it "doesn't reset the attempt count when an old copy of the session cookie is replayed" do
    request_code(volunteer.email)
    fresh_cookie = cookies.to_hash.dup

    5.times { post training_sign_in_verify_path, params: { code: "000000" } }
    fresh_cookie.each { |name, value| cookies[name] = value }
    post training_sign_in_verify_path, params: { code: "123456" }

    expect(response).to redirect_to(training_sign_in_path)
    get training_path
    expect(response).to redirect_to(training_sign_in_path)
  end

  it "caps how many codes one address gets, whichever browser asks" do
    5.times do
      reset!
      expect { request_code(volunteer.email) }.to have_enqueued_mail(TrainingMailer, :sign_in_code)
    end
    reset!
    expect { request_code(volunteer.email) }.not_to have_enqueued_mail(TrainingMailer, :sign_in_code)
    expect(response).to redirect_to(training_sign_in_path)
    expect(flash[:alert]).to include("for that address")
  end

  it "challenges a code request for a different address than the pending one" do
    request_code(volunteer.email)
    allow(TurnstileVerifier).to receive(:verify).and_return(false)

    expect { request_code(volunteer.email) }.to have_enqueued_mail(TrainingMailer, :sign_in_code)
    expect { request_code("someone-else@example.com") }.not_to have_enqueued_mail(TrainingMailer, :sign_in_code)
    expect(flash[:alert]).to include("verify that you're human")
  end

  it "won't sign in someone who was given a role after the code went out" do
    request_code(volunteer.email)
    create(:event_role_assignment, user: volunteer, event: event, role: "ops")
    post training_sign_in_verify_path, params: { code: "123456" }

    expect(response).to redirect_to(training_sign_in_path)
    get training_path
    expect(response).to redirect_to(training_sign_in_path)
  end
end
