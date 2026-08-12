require "rails_helper"

RSpec.describe "Admin::ExportTemplates", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "admin-templates@example.com", name: "Admin", global_role: "global_admin") }

  describe "POST create" do
    before { sign_in admin }

    it "saves a template with columns and filters" do
      expect {
        post admin_event_export_templates_path(event_slug: event.slug),
          params: {
            template_name: "Complete emails",
            columns: [ "participant.email" ],
            filters: { "0" => { field: "participant_event.status", operator: "in", value: [ "complete" ] } },
            row_mode: "participant"
          }
      }.to change(ExportTemplate, :count).by(1)

      template = ExportTemplate.order(:created_at).last
      expect(template.name).to eq("Complete emails")
      expect(template.columns).to eq([ "participant.email" ])
      expect(template.filters.first["field"]).to eq("participant_event.status")
      expect(template.created_by).to eq(admin)
      expect(response).to redirect_to(admin_event_exports_path(event_slug: event.slug, template_id: template.id))
    end

    it "rejects templates with unknown columns" do
      expect {
        post admin_event_export_templates_path(event_slug: event.slug),
          params: { template_name: "Bad", columns: [ "participant.ssn" ] }
      }.not_to change(ExportTemplate, :count)

      expect(flash[:alert]).to include("not authorized")
    end

    it "rejects templates containing fields the user cannot export" do
      ops = User.create!(email: "ops-templates@example.com", name: "Ops")
      EventRoleAssignment.create!(user: ops, event: event, role: "ops")
      sign_in ops

      expect {
        post admin_event_export_templates_path(event_slug: event.slug),
          params: { template_name: "Sneaky", columns: [ "medical.allergies" ] }
      }.not_to change(ExportTemplate, :count)

      expect(flash[:alert]).to include("not authorized")
    end

    it "requires a name" do
      post admin_event_export_templates_path(event_slug: event.slug),
        params: { columns: [ "participant.email" ] }

      expect(flash[:alert]).to include("Name can't be blank")
    end
  end

  describe "DELETE destroy" do
    it "deletes own templates" do
      sign_in admin
      template = create(:export_template, event: event, created_by: admin)

      expect {
        delete admin_event_export_template_path(event_slug: event.slug, id: template.id)
      }.to change(ExportTemplate, :count).by(-1)
    end

    it "prevents non-owners without admin rights from deleting" do
      template = create(:export_template, event: event)
      ops = User.create!(email: "ops-del@example.com", name: "Ops")
      EventRoleAssignment.create!(user: ops, event: event, role: "ops")
      sign_in ops

      expect {
        delete admin_event_export_template_path(event_slug: event.slug, id: template.id)
      }.not_to change(ExportTemplate, :count)

      expect(flash[:alert]).to include("not authorized")
    end

    it "cannot delete templates belonging to another event" do
      sign_in admin
      other_template = create(:export_template)

      expect {
        delete admin_event_export_template_path(event_slug: event.slug, id: other_template.id)
      }.not_to change(ExportTemplate, :count)

      expect(flash[:alert]).to include("could not be found")
    end
  end
end
