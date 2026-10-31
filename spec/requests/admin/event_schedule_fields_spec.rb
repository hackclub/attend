require "rails_helper"

# The event form and the setup wizard's schedule step both edit the event's
# six schedule times. They're typed and prefilled on the event's clock and
# shown as 24-hour times (lang="en-GB").
RSpec.describe "Admin event schedule fields", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-schedule-fields@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) do
    create(:event,
      timezone: "Pacific Time (US & Canada)",
      starts_at: Time.utc(2030, 7, 12, 16, 30),
      ends_at: Time.utc(2030, 7, 14, 23, 0),
      registration_open_at: Time.utc(2030, 1, 1, 17, 0),
      registration_close_at: Time.utc(2030, 6, 1, 6, 59),
      arrival_opens_at: Time.utc(2030, 7, 12, 15, 0),
      arrival_closes_at: Time.utc(2030, 7, 12, 18, 0))
  end

  # Event-local wall-clock for each stored UTC time above (PDT is UTC-7).
  let(:expected_values) do
    {
      "starts_at" => "2030-07-12T09:30",
      "ends_at" => "2030-07-14T16:00",
      "registration_open_at" => "2030-01-01T09:00",
      "registration_close_at" => "2030-05-31T23:59",
      "arrival_opens_at" => "2030-07-12T08:00",
      "arrival_closes_at" => "2030-07-12T11:00"
    }
  end

  before { sign_in admin }

  def doc
    Nokogiri::HTML(response.body)
  end

  def expect_event_local_24h_fields
    expected_values.each do |attr, value|
      field = doc.at_css("input[name='event[#{attr}]']")
      expect(field["type"]).to eq("datetime-local")
      expect(field["lang"]).to eq("en-GB")
      expect(field["value"]).to eq(value)
    end
  end

  [ false, true ].each do |console|
    context(console ? "with the admin console beta" : "in the original admin") do
      before { admin.update!(admin_console_beta: console) }

      it "prefills the event form on the event's clock in 24-hour fields" do
        get edit_admin_event_path(event)

        expect(response).to have_http_status(:ok)
        expect_event_local_24h_fields
        set_above = console ? "Location and time" : "Location & Time"
        expect(doc.text.squish).to include("Times are in the event's time zone, set under #{set_above} above.")
      end

      it "prefills the setup schedule step on the event's clock in 24-hour fields" do
        get admin_event_setup_schedule_path(event)

        expect(response).to have_http_status(:ok)
        expect_event_local_24h_fields
        expect(doc.text.squish).to include("Times are in the event's time zone: Pacific Time (US & Canada).")
      end
    end
  end
end
