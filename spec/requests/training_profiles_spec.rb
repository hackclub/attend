require "rails_helper"

RSpec.describe "Training details", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:course) { create(:training_course, :published, access: "open") }
  let(:details) { attributes_for(:training_profile) }

  def form_value(name)
    field = Nokogiri::HTML(response.body).at_css("[name='training_profile[#{name}]']")
    field.name == "select" ? field.at_css("option[selected]")&.[]("value") : field["value"]
  end

  context "signed in with Hack Club Auth" do
    let(:learner) do
      create(:user, name: "Example Preferred", hack_club_account_id: "hca-example-42", oidc_claims: {
        "legal_first_name" => "Example", "legal_last_name" => "Learner",
        "phone_number" => "+12025550178",
        "addresses" => [
          { "line_1" => "9 Other Road", "city" => "Elsewhere", "country" => "CA", "primary" => false },
          { "line_1" => "2 Example Avenue", "line_2" => "Unit 3", "city" => "Exampleville", "state" => "VT", "postal_code" => "05401", "country" => "US", "primary" => true }
        ]
      })
    end

    before { sign_in learner }

    it "asks before any course, filled in from the account, and goes back to where they were" do
      get training_course_path(course)
      expect(response).to redirect_to(edit_training_profile_path)

      get training_path
      expect(response).to redirect_to(edit_training_profile_path)

      follow_redirect!
      expect(response.body).to include("Before you start", "filled in what your Hack Club account has", learner.email)
      expect(form_value(:full_name)).to eq("Example Learner")
      expect(form_value(:phone_number)).to eq("+12025550178")
      expect(form_value(:address_line_1)).to eq("2 Example Avenue")
      expect(form_value(:city)).to eq("Exampleville")
      expect(form_value(:country)).to eq("United States")

      patch training_profile_path, params: { training_profile: details.merge(full_name: "Example Learner") }
      expect(response).to redirect_to(training_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "keeps the name Hack Club Auth gave" do
      patch training_profile_path, params: { training_profile: details }
      expect(learner.reload.name).to eq("Example Preferred")
    end
  end

  context "signed in with an emailed code" do
    let(:volunteer) { create(:user, name: nil, email: "code-volunteer@example.com") }

    before do
      create(:event_volunteer, user: volunteer)
      sign_in volunteer
    end

    it "starts empty, and names the account from what they give" do
      get edit_training_profile_path
      expect(response.body).not_to include("filled in what your Hack Club account has")
      expect(form_value(:full_name)).to be_nil
      expect(response.body).to include("code-volunteer@example.com")

      patch training_profile_path, params: { training_profile: details.merge(phone_number: "(202) 555-0143") }

      profile = volunteer.reload.training_profile
      expect(profile.phone_number).to eq("+12025550143")
      expect(profile.connection_label).to eq("Parent or guardian of a participant")
      expect(volunteer.name).to eq("Example Volunteer")
    end
  end

  context "as anyone" do
    let(:learner) { create(:user) }

    before { sign_in learner }

    it "needs every required field and a real phone number" do
      patch training_profile_path, params: { training_profile: details.merge(connection_detail: "", phone_number: "555", city: " ") }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Tell us more can&#39;t be blank", "City can&#39;t be blank", "Phone number isn&#39;t one we can call")
      expect(learner.reload.training_profile).to be_nil
    end

    it "turns away a connection that isn't on the list" do
      patch training_profile_path, params: { training_profile: details.merge(connection_type: "made_up") }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(learner.reload.training_profile).to be_nil
    end

    it "keeps the phone number, address and connection encrypted and out of the version history" do
      patch training_profile_path, params: { training_profile: details }

      raw = TrainingProfile.connection.select_one("SELECT phone_number, address_line_1, connection_detail FROM training_profiles")
      expect(raw.values.join).not_to include("+12025550143", "1 Example Street", "Example Participant")
      changes = PaperTrail::Version.where(item_type: "TrainingProfile").pluck(:object_changes).join
      expect(changes).not_to include("+12025550143", "1 Example Street", "Example Participant")
    end

    it "lets them change their details later" do
      create(:training_profile, user: learner)

      get edit_training_profile_path
      expect(response.body).to include("Your details", "Save details")

      patch training_profile_path, params: { training_profile: { connection_type: "teacher", connection_detail: "Teacher at Example High" } }
      expect(response).to redirect_to(edit_training_profile_path)
      expect(learner.reload.training_profile.connection_detail).to eq("Teacher at Example High")
    end
  end

  describe "on the event staff page" do
    let(:event) { create(:event) }
    let(:volunteer) { create(:event_volunteer, event: event).user }

    before do
      create(:training_profile, user: volunteer, connection_detail: "Parent of Example Kid")
    end

    [ true, false ].each do |console|
      it "shows event admins how each person is connected and their phone (#{console ? "console" : "original"})" do
        admin = create(:event_role_assignment, event: event, role: "event_admin").user
        admin.update!(admin_console_beta: console)
        sign_in admin
        get select_admin_event_path(slug: event.slug)

        get admin_event_staff_index_path(event_slug: event.slug)
        expect(response.body).to include("Parent of Example Kid", "tel:+12025550143")
      end

      it "keeps phone numbers from staff who don't manage staff (#{console ? "console" : "original"})" do
        staff = create(:event_role_assignment, event: event, role: "ops").user
        staff.update!(admin_console_beta: console)
        sign_in staff
        get select_admin_event_path(slug: event.slug)

        get admin_event_staff_index_path(event_slug: event.slug)
        expect(response.body).to include("Parent of Example Kid")
        expect(response.body).not_to include("tel:+12025550143")
      end
    end
  end

  [ true, false ].each do |console|
    it "shows global admins everything on the user page (#{console ? "console" : "original"})" do
      admin = create(:user, global_role: "global_admin", admin_console_beta: console)
      profile = create(:training_profile)
      sign_in admin

      get admin_user_path(profile.user)
      expect(response.body).to include("Parent of Example Participant", "tel:+12025550143", "1 Example Street", "Exampleton, VT, 05401")
    end
  end
end
