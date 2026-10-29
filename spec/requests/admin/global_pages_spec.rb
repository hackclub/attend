require "rails_helper"

# Pages that aren't about any one event (Admin::BaseController.global_page)
# keep the picked event folded away in the side nav, and nothing done on them
# is attributed to it.
RSpec.describe "Admin pages that aren't about an event", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event, name: "Picked Hacks") }

  before do
    sign_in admin
    get select_admin_event_path(slug: event.slug)
  end

  # The side nav groups (details elements) named after the event.
  def event_groups
    Nokogiri::HTML(response.body).css("details").select { |group| group.at_css("summary").text.include?("Picked Hacks") }
  end

  { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
    context ui do
      before { admin.update!(admin_console_beta: console) }

      it "folds the picked event's links away in the side nav" do
        get admin_visa_letter_templates_path

        expect(event_groups).not_to be_empty
        event_groups.each do |group|
          expect(group["open"]).to be_nil
          expect(group.at_css("a[href='#{admin_event_participants_path(event)}']")).to be_present
        end
      end

      it "keeps them out in the open on the event's own pages" do
        get admin_event_participants_path(event)

        expect(event_groups).to be_empty
        expect(response.body).to include(admin_event_participants_path(event))
      end
    end
  end

  it "heads the console side nav with Attend instead of the event" do
    get admin_visa_letter_templates_path
    expect(Nokogiri::HTML(response.body).css(".cs-sidenav-header").map { |header| header.text.squish }.uniq).to eq([ "Attend admin Hack Club events" ])

    get admin_event_participants_path(event)
    expect(Nokogiri::HTML(response.body).at_css(".cs-sidenav-header").text).to include("Picked Hacks")
  end

  it "doesn't audit-log what's done on them against the picked event" do
    post admin_visa_letter_templates_path, params: { visa_letter_template: {
      name: "Default letter", body: VisaLetterTemplate::STARTER_BODY, signatory_name: "Fictional Signatory",
      signatory_title: "Executive Director", is_default: "1", active: "1"
    } }
    template = VisaLetterTemplate.find_by!(name: "Default letter")
    expect(AuditLog.find_by!(record: template, action: "create").event_id).to be_nil

    post admin_user_impersonation_path(create(:user))
    expect(AuditLog.find_by!(action: "impersonate").event_id).to be_nil
  end

  it "still audit-logs the event's own pages against it" do
    patch admin_event_path(event), params: { event: { name: "Renamed Hacks" } }

    expect(AuditLog.find_by!(record: event, action: "update").event_id).to eq(event.id)
  end

  it "audit-logs a new event against itself rather than the picked one" do
    post admin_events_path, params: { event: { name: "Wizard Con", slug: "wizard-con", support_email: "wizard@hackclub.com" } }

    new_event = Event.find_by!(slug: "wizard-con")
    expect(AuditLog.find_by!(record: new_event, action: "create").event_id).to eq(new_event.id)
  end
end
