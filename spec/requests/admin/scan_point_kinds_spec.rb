require "rails_helper"

# Scan point kinds and the status cell, in the original admin and the console beta.
RSpec.describe "Scan point kinds in the admin", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now) }
  let(:admin) { create(:user, global_role: "global_admin") }

  before { sign_in admin }

  [ true, false ].each do |console|
    context(console ? "in the console beta" : "in the original admin") do
      before { admin.update!(admin_console_beta: console) }

      it "saves a kind and a usage note, and writes the old flags to match" do
        get new_admin_event_scan_context_path(event)
        expect(response.body).to include("What a scan here means", "When to use this")

        post admin_event_scan_contexts_path(event), params: {
          scan_context: { name: "Bus tour", kind: "supervised_outing", usage_note: "Scan as they board the bus." }
        }

        expect(event.scan_contexts.find_by!(name: "Bus tour"))
          .to have_attributes(kind: "supervised_outing", usage_note: "Scan as they board the bus.", checks_in: false)
        get admin_event_scan_contexts_path(event)
        expect(response.body).to include("Supervised outing", "Scan as they board the bus.")
        get scanner_admin_event_scans_path(event)
        expect(response.body).to include('data-role-info-target="panel"', "Scan as they board the bus.")
      end

      it "shows where a participant is in the status cell" do
        registration = create(:participant_event, :checked_in, event: event)

        get admin_event_participant_path(event, registration)

        expect(response.body).to include("At venue")
      end
    end
  end

  it "loads every row's status without a query per row" do
    queries = lambda do
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get admin_event_participants_path(event) }
      count
    end

    create_list(:participant_event, 2, :checked_in, event: event)
    queries.call # the first visit also stores the current event in the session
    with_two = queries.call
    create_list(:participant_event, 4, :checked_in, event: event)

    expect(queries.call).to eq(with_two)
  end
end
