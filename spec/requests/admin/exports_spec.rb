require "rails_helper"

RSpec.describe "Admin::Exports", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "admin-exports@example.com", name: "Admin", global_role: "global_admin") }

  def sign_in_with_role(role)
    user = User.create!(email: "#{role}-exports@example.com", name: role.titleize)
    EventRoleAssignment.create!(user: user, event: event, role: role)
    sign_in user
    user
  end

  describe "GET index" do
    it "shows all categories to a global admin" do
      sign_in admin
      get admin_event_exports_path(event_slug: event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Medical", "Safeguarding", "Travel")
    end

    it "hides sensitive categories and their presets from ops" do
      sign_in_with_role("ops")
      get admin_event_exports_path(event_slug: event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Travel")
      expect(response.body).not_to include("medical.allergies", "safeguarding.high_support_flag")
      expect(response.body).to include("preset=participants", "preset=travel")
      expect(response.body).not_to include("preset=medical_flags", "preset=dietary")
    end

    it "shows sensitive presets to safeguarding leads but not general ones" do
      sign_in_with_role("safeguarding_lead")
      get admin_event_exports_path(event_slug: event.slug)

      expect(response.body).to include("preset=medical_flags", "preset=dietary", "preset=accommodation")
      expect(response.body).not_to include("preset=participants", "preset=travel")
    end

    it "strips unpermitted fields from a loaded template and warns" do
      template = create(:export_template, event: event, created_by: admin,
        columns: [ "participant.email", "medical.allergies" ],
        filters: [ { "field" => "medical.has_anaphylaxis_risk", "operator" => "true" } ])
      sign_in_with_role("ops")

      get admin_event_exports_path(event_slug: event.slug, template_id: template.id)

      expect(response.body).to include("not authorized to export", "Allergies", "Has Anaphylaxis Risk")
      expect(response.body).not_to include("medical.allergies")
    end
  end

  describe "POST create" do
    before { sign_in admin }

    let!(:pe) { create(:participant_event, event: event, status: "complete") }

    it "exports the selected columns as CSV" do
      post admin_event_exports_path(event_slug: event.slug),
        params: { columns: [ "participant.email", "participant_event.status" ] }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      rows = CSV.parse(response.body)
      expect(rows.first).to eq([ "Email", "Status" ])
      expect(rows.last).to eq([ pe.participant.email, "complete" ])
    end

    it "applies filters from params" do
      create(:participant_event, event: event, status: "invited")

      post admin_event_exports_path(event_slug: event.slug),
        params: {
          columns: [ "participant.email" ],
          filters: { "0" => { field: "participant_event.status", operator: "in", value: [ "complete" ] } }
        }

      expect(CSV.parse(response.body).size).to eq(2)
    end

    it "writes an audit log with the export configuration" do
      expect {
        post admin_event_exports_path(event_slug: event.slug), params: { columns: [ "participant.email" ] }
      }.to change { AuditLog.where(action: "export").count }.by(1)

      metadata = AuditLog.where(action: "export").order(:created_at).last.metadata
      expect(metadata["columns"]).to eq([ "participant.email" ])
      expect(metadata["row_count"]).to eq(1)
    end

    it "rejects unknown fields" do
      post admin_event_exports_path(event_slug: event.slug), params: { columns: [ "participant.ssn" ] }

      expect(response).to redirect_to(admin_event_exports_path(event_slug: event.slug))
      expect(flash[:alert]).to include("Unknown export fields")
    end

    it "rejects invalid filters" do
      post admin_event_exports_path(event_slug: event.slug),
        params: {
          columns: [ "participant.email" ],
          filters: { "0" => { field: "participant_event.checked_in_at", operator: "before", value: "not-a-date" } }
        }

      expect(response).to redirect_to(admin_event_exports_path(event_slug: event.slug))
      expect(flash[:alert]).to include("Invalid filter")
    end

    it "requires at least one column" do
      post admin_event_exports_path(event_slug: event.slug), params: { columns: [] }

      expect(flash[:alert]).to include("at least one column")
    end

    it "maps legacy export_type params to presets" do
      post admin_event_exports_path(event_slug: event.slug), params: { export_type: "participants" }

      expect(response.media_type).to eq("text/csv")
      expect(CSV.parse(response.body).first).to include("Legal First Name", "Email", "Status")
    end

    it "rejects invalid legacy export types" do
      post admin_event_exports_path(event_slug: event.slug), params: { export_type: "everything" }

      expect(flash[:alert]).to eq("Invalid export type.")
    end

    context "as ops" do
      before { sign_in_with_role("ops") }

      it "denies sensitive columns and does not log an export" do
        expect {
          post admin_event_exports_path(event_slug: event.slug),
            params: { columns: [ "participant.email", "medical.allergies" ] }
        }.not_to change { AuditLog.where(action: "export").count }

        expect(response).to redirect_to(admin_event_exports_path(event_slug: event.slug))
        expect(flash[:alert]).to include("not authorized to export", "Allergies")
      end

      it "denies sensitive filter fields even with permitted columns" do
        post admin_event_exports_path(event_slug: event.slug),
          params: {
            columns: [ "participant.email" ],
            filters: { "0" => { field: "medical.has_anaphylaxis_risk", operator: "true" } }
          }

        expect(flash[:alert]).to include("not authorized to export")
      end

      it "allows general columns" do
        post admin_event_exports_path(event_slug: event.slug), params: { columns: [ "participant.email" ] }

        expect(response.media_type).to eq("text/csv")
      end
    end

    context "with a saved template" do
      let(:template) do
        create(:export_template, event: event, created_by: admin,
          columns: [ "participant.email", "medical.allergies" ],
          filters: [ { "field" => "participant_event.status", "operator" => "in", "value" => [ "complete" ] } ])
      end

      it "runs the template" do
        pe.create_medical!(allergies: "peanuts")

        post admin_event_exports_path(event_slug: event.slug), params: { template_id: template.id }

        expect(response.media_type).to eq("text/csv")
        rows = CSV.parse(response.body)
        expect(rows.first).to eq([ "Email", "Allergies" ])
        expect(rows.last).to eq([ pe.participant.email, "peanuts" ])
      end

      it "re-checks permissions when a template is run" do
        sign_in_with_role("ops")

        post admin_event_exports_path(event_slug: event.slug), params: { template_id: template.id }

        expect(response).to redirect_to(admin_event_exports_path(event_slug: event.slug))
        expect(flash[:alert]).to include("not authorized to export")
      end
    end
  end
end
