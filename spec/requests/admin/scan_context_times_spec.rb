require "rails_helper"

# A scan point's schedule is typed, prefilled and shown on the event's clock,
# in 24-hour fields. Points saved before that keep their UTC reading.
RSpec.describe "Scan context times in the admin", type: :request do
  include Devise::Test::IntegrationHelpers

  # Boston: UTC-4 in July.
  let(:event) { create(:event, timezone: "Eastern Time (US & Canada)") }
  let(:admin) { create(:user, global_role: "global_admin") }

  before { sign_in admin }

  def page
    Nokogiri::HTML5(response.body)
  end

  def page_text
    page.text.squish
  end

  [ true, false ].each do |console|
    context(console ? "in the console beta" : "in the original admin") do
      before { admin.update!(admin_console_beta: console) }

      it "reads typed times on the event's clock" do
        post admin_event_scan_contexts_path(event), params: {
          scan_context: { name: "Dinner", kind: "tracking_only", starts_at: "2030-07-12T18:00", ends_at: "2030-07-12T20:30" }
        }

        dinner = event.scan_contexts.find_by!(name: "Dinner")
        expect(dinner.starts_at).to eq(Time.utc(2030, 7, 12, 22, 0))
        expect(dinner.ends_at).to eq(Time.utc(2030, 7, 13, 0, 30))
        expect(dinner.times_in_event_zone).to be(true)
      end

      it "offers 24-hour fields that say which zone they're in" do
        get new_admin_event_scan_context_path(event)

        %w[starts_at ends_at].each do |attr|
          expect(page.at_css("input#scan_context_#{attr}")["lang"]).to eq("en-GB")
        end
        expect(page_text).to include("In the event's time zone: Eastern Time (US & Canada).")
      end

      it "prefills and lists a schedule on the event's clock" do
        dinner = event.scan_contexts.create!(name: "Dinner", starts_at: "2030-07-12T18:00", ends_at: "2030-07-12T20:30")

        get edit_admin_event_scan_context_path(event, dinner)
        expect(page.at_css("input#scan_context_starts_at")["value"]).to eq("2030-07-12T18:00")
        expect(page.at_css("input#scan_context_ends_at")["value"]).to eq("2030-07-12T20:30")

        get admin_event_scan_contexts_path(event)
        if console
          expect(page_text).to include("July 12, 2030, 18:00 (UTC-4:00) – July 12, 2030, 20:30 (UTC-4:00)")
        else
          expect(page_text).to include("Jul 12, 6:00 PM – Jul 12, 8:30 PM")
        end
      end

      it "re-renders a rejected form with the times as typed" do
        post admin_event_scan_contexts_path(event), params: {
          scan_context: { name: "Dinner", kind: "tracking_only", starts_at: "2030-07-12T18:00", ends_at: "2030-07-12T17:00" }
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css("input#scan_context_starts_at")["value"]).to eq("2030-07-12T18:00")
        expect(page.at_css("input#scan_context_ends_at")["value"]).to eq("2030-07-12T17:00")
      end

      context "with a point saved before times were zoned" do
        # As older code stored it: the typed wall-clock, tagged UTC.
        let!(:dinner) do
          event.scan_contexts.create!(name: "Dinner", starts_at: Time.utc(2030, 7, 12, 18, 0), ends_at: Time.utc(2030, 7, 12, 20, 30))
            .tap { |c| c.update_column(:times_in_event_zone, false) }
        end

        it "keeps prefilling and listing it on UTC" do
          get edit_admin_event_scan_context_path(event, dinner)
          expect(page.at_css("input#scan_context_starts_at")["value"]).to eq("2030-07-12T18:00")

          get admin_event_scan_contexts_path(event)
          if console
            expect(page_text).to include("July 12, 2030, 18:00 (UTC+0:00) – July 12, 2030, 20:30 (UTC+0:00)")
          else
            expect(page_text).to include("Jul 12, 6:00 PM – Jul 12, 8:30 PM")
          end
        end

        it "moves it onto the event's clock when the form is saved" do
          patch admin_event_scan_context_path(event, dinner), params: {
            scan_context: { name: "Dinner", starts_at: "2030-07-12T18:00", ends_at: "2030-07-12T20:30" }
          }

          expect(dinner.reload).to have_attributes(
            starts_at: Time.utc(2030, 7, 12, 22, 0), ends_at: Time.utc(2030, 7, 13, 0, 30), times_in_event_zone: true
          )
        end
      end
    end
  end
end
