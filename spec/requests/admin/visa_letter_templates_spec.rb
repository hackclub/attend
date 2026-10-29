require "rails_helper"

RSpec.describe "Admin visa letter templates", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, email: "templates-admin@example.com", global_role: "global_admin", admin_console_beta: false) }

  before { sign_in admin }

  { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
    context ui do
      before { admin.update!(admin_console_beta: console) }

      it "warns when there's no default, and starts a new template from Envoy's wording" do
        get admin_visa_letter_templates_path
        expect(response.body).to include("no active default template")

        get new_admin_visa_letter_template_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("{{participant_full_name}} is invited to participate")
      end

      it "adds, edits, previews and removes a template" do
        post admin_visa_letter_templates_path, params: { visa_letter_template: {
          name: "Default letter", body: VisaLetterTemplate::STARTER_BODY, signatory_name: "Fictional Signatory",
          signatory_title: "Executive Director", is_default: "1", active: "1"
        } }
        template = VisaLetterTemplate.find_by!(name: "Default letter")
        expect(template).to have_attributes(is_default: true, event_id: nil)

        get preview_admin_visa_letter_template_path(template)
        expect(response.media_type).to eq("application/pdf")
        text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ").squish
        expect(text).to include("Ada Example")

        patch admin_visa_letter_template_path(template), params: { visa_letter_template: { signatory_title: "Director" } }
        expect(template.reload.signatory_title).to eq("Director")

        delete admin_visa_letter_template_path(template)
        expect(VisaLetterTemplate.exists?(template.id)).to be(false)
      end

      it "shows what's wrong with an invalid template" do
        post admin_visa_letter_templates_path, params: { visa_letter_template: { name: "", body: "Too short", signatory_name: "", signatory_title: "" } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(VisaLetterTemplate.count).to eq(0)
      end
    end
  end

  it "is for global admins only" do
    event_admin = create(:user).tap { |user| create(:event_role_assignment, user: user, role: "event_admin") }
    sign_in event_admin

    get admin_visa_letter_templates_path

    expect(response).to redirect_to(root_path)
  end
end
