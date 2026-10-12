require "rails_helper"

# Console forms follow Cloudscape's validation pattern
# (cloudscape.design/patterns/general/errors/validation): after a failed
# submit, each field's error sits under that field with aria-invalid and
# aria-describedby on the control, errors no field owns go in an alert just
# before the form's actions, and there's no generic summary at the top.
RSpec.describe "Admin console form validation", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) do
    User.create!(email: "validation-admin@example.com", name: "Robin Placeholder",
      global_role: "global_admin", admin_console_beta: true)
  end
  let(:event) { create(:event, name: "Validation Test Jam", groups_enabled: true) }

  before { sign_in admin }

  def page
    @pages ||= {}
    @pages[response.body] ||= Nokogiri::HTML(response.body)
  end

  def main_form
    page.css("main form").reject { |form| form.ancestors("template").any? }.max_by { |form| form.css("input, select, textarea").size }
  end

  # The inline error for the control with this id: the control is marked
  # invalid and described by the error element, which sits in the same field.
  def inline_error(control_id)
    control = page.at_css("##{control_id}")
    expect(control).to be_present, "no control ##{control_id}"
    expect(control["aria-invalid"]).to eq("true"), "##{control_id} should be aria-invalid"
    error_id = control["aria-describedby"].to_s.split.find { |id| id.end_with?("-error") }
    expect(error_id).to be_present, "##{control_id} should be described by its error"
    error = page.at_css("##{error_id}")
    expect(error["class"]).to include("cs-field-error")
    expect(error.at_css("svg")).to be_present
    expect(control.ancestors("[data-cs-field]").first).to eq(error.ancestors("[data-cs-field]").first)
    error.text.strip
  end

  def expect_valid(control_id)
    control = page.at_css("##{control_id}")
    expect(control["aria-invalid"]).to be_nil, "##{control_id} shouldn't be aria-invalid"
  end

  def expect_no_top_summary
    form = main_form
    first_block = form.element_children.reject { |child| child.name == "input" }.first
    expect(first_block["class"].to_s).not_to include("cs-alert-error")
    expect(response.body).not_to match(/prohibited this|stopped this|Fix all errors/i)
  end

  # The end-of-form alert comes after every field and before the actions.
  def form_alert
    form = main_form
    alert = form.at_css(".cs-alert.cs-alert-error.cs-form-error")
    return nil unless alert

    nodes = form.css("*").to_a
    last_field = form.css("[data-cs-field]").last
    submit = form.css("button[type=submit], input[type=submit], button:not([type])").last
    expect(nodes.index(alert)).to be > nodes.index(last_field) if last_field
    expect(nodes.index(alert)).to be < nodes.index(submit)
    alert
  end

  def validated_form?
    form = main_form
    form["novalidate"].present? && form["data-controller"].to_s.split.include?("cs-form-validation")
  end

  describe "new event" do
    it "puts required and format errors under their fields" do
      post admin_events_path, params: { event: { name: "", slug: "", support_email: "someone@example.org", timezone: "UTC" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(validated_form?).to be(true)
      expect(inline_error("event_name")).to eq("Event name is required.")
      expect(inline_error("event_support_email")).to eq(
        "Enter an email address ending in @hackclub.com, @events.hackclub.com, or @haven.hackclub.com."
      )
      expect(form_alert).to be_nil
      expect_no_top_summary
    end

    it "explains a duplicate slug as a conflict" do
      create(:event, slug: "taken-slug")
      post admin_events_path, params: { event: { name: "Another Jam", slug: "taken-slug", support_email: "team@hackclub.com", timezone: "UTC" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(inline_error("event_slug")).to eq("This slug is already in use.")
      expect_valid("event_name")
      expect_valid("event_support_email")
    end

    it "marks optional fields, leaves required ones unmarked and carries constraint text" do
      get admin_new_event_path

      name_label = page.at_css("label[for=event_name]")
      expect(name_label.text.strip).to eq("Event name")
      slug_label = page.at_css("label[for=event_slug]")
      expect(slug_label.at_css(".cs-field-optional").text).to eq(" - optional")
      slug = page.at_css("#event_slug")
      expect(slug["aria-describedby"]).to eq("event_slug-constraint")
      expect(page.at_css("#event_slug-constraint").text).to include("Lowercase letters, numbers and hyphens (-) only.")
      expect(slug["aria-invalid"]).to be_nil
      expect(page.css(".cs-field-error")).to be_empty
    end
  end

  describe "edit event" do
    it "shows errors inline on the full settings form" do
      patch admin_event_path(event), params: { event: { name: "", support_email: "team@example.org", visa_application_url: "not a url" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(validated_form?).to be(true)
      expect(inline_error("event_name")).to eq("Event name is required.")
      expect(inline_error("event_support_email")).to start_with("Enter an email address ending in @hackclub.com")
      expect(page.at_css("label[for=event_visa_application_url] .cs-field-optional")).to be_present
      expect_no_top_summary
    end
  end

  describe "scan context" do
    it "shows the name and time-order errors inline" do
      post admin_event_scan_contexts_path(event), params: {
        scan_context: { name: "", checks_in: "1", starts_at: "2026-07-12T10:00", ends_at: "2026-07-12T09:00" }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(validated_form?).to be(true)
      expect(inline_error("scan_context_name")).to eq("Location name is required.")
      expect(inline_error("scan_context_ends_at")).to eq("Ends at must be after the start time.")
      expect(form_alert).to be_nil
      expect_no_top_summary
    end
  end

  describe "group" do
    it "shows duplicate-name, slug format and color errors under their fields" do
      Group.find_or_create_by!(event: event, name: "Hardware")

      post admin_event_groups_path(event), params: { group: { name: "hardware", slug: "Bad Slug", color: "red" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(inline_error("group_name")).to eq("This name is already in use by another group in this event.")
      expect(inline_error("group_slug")).to eq("Enter a valid slug. Use lowercase letters, numbers and hyphens (-) only.")
      expect(inline_error("group_color")).to eq("Enter a valid hex color. For example: #ec3750")
      expect_valid("group_description")
      expect_no_top_summary
    end

    it "puts an error no field owns in the alert before the actions" do
      allow_any_instance_of(Group).to receive(:save) do |group|
        group.errors.add(:base, "The group couldn't be saved. Try again in a few minutes.")
        false
      end

      post admin_event_groups_path(event), params: { group: { name: "Software" } }

      expect(response).to have_http_status(:unprocessable_entity)
      alert = form_alert
      expect(alert).to be_present
      expect(alert["role"]).to eq("alert")
      expect(alert.text.strip).to eq("The group couldn't be saved. Try again in a few minutes.")
      expect_valid("group_name")
      expect_no_top_summary
    end

    it "re-renders the edit page with inline errors" do
      group = Group.create!(event: event, name: "Hardware")
      Group.create!(event: event, name: "Software")

      patch admin_event_group_path(event, group), params: { group: { name: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(inline_error("group_name")).to eq("Name is required.")
    end
  end

  describe "ban" do
    it "shows each address's error under that address and the missing-address error under Emails" do
      post admin_bans_path, params: { ban: { ban_emails_attributes: { "0" => { email: "not-an-address" } } } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(validated_form?).to be(true)
      expect(inline_error("ban_ban_emails_attributes_0_email")).to eq("Enter a valid email address. For example: name@example.com")
      expect(form_alert).to be_nil
      expect_no_top_summary
    end

    it "asks for at least one address" do
      post admin_bans_path, params: { ban: { reason: "Made-up reason", ban_emails_attributes: { "0" => { email: "" } } } }

      expect(response).to have_http_status(:unprocessable_entity)
      emails = page.at_css("fieldset[data-cs-field]")
      expect(emails.at_css("legend").text).to eq("Emails")
      expect(emails.at_css(".cs-field-error").text.strip).to eq("Add at least one email address.")
      expect(form_alert).to be_nil
    end

    it "explains an address that's already banned" do
      Ban.create!(created_by: admin, ban_emails_attributes: [ { email: "already-banned@example.com" } ])

      post admin_bans_path, params: { ban: { ban_emails_attributes: { "0" => { email: "already-banned@example.com" } } } }

      expect(inline_error("ban_ban_emails_attributes_0_email")).to eq("This email address is already on a ban list.")
    end
  end

  describe "user" do
    it "shows required and conflict errors inline" do
      post admin_users_path, params: { user: { email: "", name: "Sam Sample", global_role: "no_role" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(validated_form?).to be(true)
      expect(inline_error("user_email")).to eq("Email is required.")
      expect_no_top_summary

      User.create!(email: "existing-user@example.com", name: "Alex Example")
      post admin_users_path, params: { user: { email: "existing-user@example.com", global_role: "no_role" } }

      expect(inline_error("user_email")).to eq("This email address already belongs to a user.")
    end
  end

  describe "original UI" do
    before { admin.update!(admin_console_beta: false) }

    it "keeps its own error summary" do
      post admin_event_scan_contexts_path(event), params: { scan_context: { name: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("prohibited this context from being saved")
      expect(response.body).to include("Name can&#39;t be blank")
      expect(response.body).not_to include("cs-field-error")
      expect(response.body).not_to include("cs-form-validation")
    end
  end
end
