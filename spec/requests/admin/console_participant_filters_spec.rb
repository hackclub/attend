require "rails_helper"

# The admin console's participant filters follow Cloudscape's filter
# patterns: applied filters as dismissible tokens, "N matches", a
# "Clear filters" link button and the "No matches" empty state. The
# original admin keeps its plain filter bar.
RSpec.describe "Admin console participant filters", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:admin) do
    User.create!(email: "console-filters@example.com", name: "Console Filters", global_role: "global_admin", admin_console_beta: true)
  end

  let!(:ada) do
    create(:participant_event, event: event, status: :complete,
      participant: create(:participant, legal_first_name: "Ada", legal_last_name: "Quillfeather", email: "ada.quill@example.com"))
  end
  let!(:bram) do
    create(:participant_event, event: event, status: :withdrawn,
      participant: create(:participant, legal_first_name: "Bram", legal_last_name: "Ottersby", email: "bram.otter@example.com"))
  end
  let!(:cleo) do
    create(:participant_event, event: event, status: :complete,
      participant: create(:participant, legal_first_name: "Cleo", legal_last_name: "Vantaberg", email: "cleo.vanta@example.com"))
  end

  before { sign_in admin }

  def document
    Nokogiri::HTML(response.body)
  end

  def tokens
    document.css("[data-testid='participant-filter-tokens'] .cs-token").map { |token| token.at_css(".cs-filter-token-text").text.squish }
  end

  def match_count
    document.at_css("[data-testid='filter-match-count']")&.text&.strip
  end

  def listed_names
    document.css("table.cs-table tbody a.cs-link-strong").map { |link| link.text.strip }
  end

  def clear_link
    document.at_css("[data-testid='participant-filter-tokens'] a.cs-filter-clear")
  end

  describe "the list view" do
    it "renders the property filter over a plain GET form with no tokens when unfiltered" do
      get admin_event_participants_path(event)

      form = document.at_css("form[data-controller~='cs-property-filter']")
      expect(form["method"]).to eq("get")
      expect(form.at_css("input[role='combobox']")["placeholder"]).to eq("Find participants")
      expect(form.at_css("[role='listbox']")).to be_present
      # The no-JS controls submit the existing params.
      expect(form.css("[data-cs-property-filter-target='fallback'] [name]").map { |field| field["name"] }).to include("search", "status", "flag", "checked_in")
      expect(document.at_css("[data-testid='participant-filter-tokens']")).to be_nil
      expect(match_count).to be_nil
      expect(listed_names.size).to eq(3)
    end

    it "shows a status token, the match count and the filtered rows" do
      get admin_event_participants_path(event), params: { status: "complete" }

      expect(tokens).to eq([ "Status = Complete" ])
      expect(match_count).to eq("2 matches")
      expect(listed_names).to contain_exactly(a_string_including("Ada"), a_string_including("Cleo"))
      expect(document.at_css("h2.cs-h2 .cs-counter").text).to eq("(2)")
      expect(clear_link["href"]).to eq(admin_event_participants_path(event))

      remove = document.at_css("[data-testid='participant-filter-tokens'] a[data-cs-property-filter-remove]")
      expect(remove["aria-label"]).to eq("Remove filter Status = Complete")
      expect(remove["href"]).to eq(admin_event_participants_path(event))
    end

    it "shows each participant's T-shirt size in its own column" do
      ada.participant.update!(tshirt_size: "m")

      get admin_event_participants_path(event)

      headers = document.css("table.cs-table thead th").map { |th| th.text.strip }
      expect(headers.index("T-shirt")).to eq(headers.index("Status") + 1)
      sizes = document.css("table.cs-table tbody tr").to_h do |row|
        [ row.at_css("a.cs-link-strong").text.strip, row.at_css("[data-testid='tshirt-size']").text.strip ]
      end
      expect(sizes.values).to contain_exactly("M", "—", "—")
      expect(sizes.find { |name, _| name.include?("Ada") }.last).to eq("M")
    end

    it "shows a flag token" do
      ada.create_medical!(has_anaphylaxis_risk: true)

      get admin_event_participants_path(event), params: { flag: "anaphylaxis" }

      expect(tokens).to eq([ "Flag = Anaphylaxis risk" ])
      expect(match_count).to eq("1 match")
      expect(listed_names).to contain_exactly(a_string_including("Ada"))
    end

    it "shows a check-in token" do
      context = ScanContext.create!(event: event, name: "Front door", checks_in: true, is_travel_pickup: false)
      Scan.create!(participant_event: bram, scan_context: context, user: admin, scanned_at: Time.current)

      get admin_event_participants_path(event), params: { checked_in: "yes" }

      expect(tokens).to eq([ "Check-in = Checked in" ])
      expect(match_count).to eq("1 match")
      expect(listed_names).to contain_exactly(a_string_including("Bram"))
    end

    it "shows the free text as a name-or-email token" do
      get admin_event_participants_path(event), params: { search: "vanta" }

      expect(tokens).to eq([ "Name or email contains “vanta”" ])
      expect(match_count).to eq("1 match")
      expect(listed_names).to contain_exactly(a_string_including("Cleo"))
      expect(document.at_css("input[name='search']")["value"]).to eq("vanta")
    end

    it "ANDs combined filters, and each token's remove link keeps the others" do
      get admin_event_participants_path(event), params: { status: "complete", search: "ada" }

      expect(tokens).to eq([ "Name or email contains “ada”", "Status = Complete" ])
      expect(document.css("[data-testid='participant-filter-tokens'] .cs-filter-operation").map(&:text)).to eq([ "and" ])
      expect(match_count).to eq("1 match")
      expect(listed_names).to contain_exactly(a_string_including("Ada"))

      hrefs = document.css("[data-testid='participant-filter-tokens'] a[data-cs-property-filter-remove]").map { |link| link["href"] }
      expect(hrefs).to eq([
        admin_event_participants_path(event, status: "complete"),
        admin_event_participants_path(event, search: "ada")
      ])
    end

    it "renders the no-match state with Clear filters when nothing matches" do
      get admin_event_participants_path(event), params: { search: "nobody-by-this-name" }

      empty = document.at_css("[data-testid='filter-no-match']")
      expect(empty.at_css(".cs-empty-title").text).to eq("No matches")
      expect(empty.text).to include("We can't find a match.")
      expect(empty.at_css("a.cs-btn").text).to eq("Clear filters")
      expect(empty.at_css("a.cs-btn")["href"]).to eq(admin_event_participants_path(event))
      expect(match_count).to eq("0 matches")
      expect(response.body).not_to include("No participants found")
    end

    it "keeps the pending-invitations tab when clearing its search" do
      get admin_event_participants_path(event), params: { status: "pending_invitations", search: "nobody" }

      expect(tokens).to eq([ "Name or email contains “nobody”" ])
      expect(clear_link["href"]).to eq(admin_event_participants_path(event, status: "pending_invitations"))
      expect(document.at_css("[data-testid='filter-no-match']")).to be_present
    end

    it "shows a dashboard's blocked-on filter as a token and keeps it on resubmit" do
      get admin_event_participants_path(event), params: { blocked_on: "waiver" }

      expect(tokens).to eq([ "Blocked on = Waiver" ])
      expect(document.at_css("form[data-controller~='cs-property-filter'] input[type='hidden'][name='blocked_on']")["value"]).to eq("waiver")
    end

    it "escapes participant-controlled text in tokens" do
      get admin_event_participants_path(event), params: { search: "<img src=x>" }

      expect(response.body).not_to include("<img src=x>")
      expect(tokens).to eq([ "Name or email contains “<img src=x>”" ])
    end
  end

  describe "the table view" do
    it "uses the same placeholder and shows panel filters as tokens with a match count" do
      get table_admin_event_participants_path(event), params: {
        filters: { "0" => { field: "status", operator: "is", value: "complete" }, "1" => { field: "legal_first_name", operator: "contains", value: "Cle" } }
      }

      expect(document.at_css("input[data-data-table-target='searchInput']")["placeholder"]).to eq("Find participants")
      table_tokens = document.css("[data-testid='table-filter-tokens'] .cs-filter-token-text").map { |token| token.text.squish }
      expect(table_tokens).to eq([ "Status = Complete", "First name contains “Cle”" ])
      expect(document.css("[data-testid='table-filter-tokens'] .cs-filter-operation").map(&:text)).to eq([ "and" ])
      expect(match_count).to eq("1 match")
      expect(document.at_css("[data-testid='table-filter-tokens'] a.cs-filter-clear")["href"]).to eq(table_admin_event_participants_path(event))

      remove_first = document.at_css("[data-testid='table-filter-tokens'] a[data-cs-property-filter-remove]")["href"]
      query = Rack::Utils.parse_nested_query(URI.parse(remove_first).query)
      expect(query["filters"]).to eq("0" => { "field" => "legal_first_name", "operator" => "contains", "value" => "Cle" })
    end

    it "shows the OR operation when the panel matches any condition" do
      get table_admin_event_participants_path(event), params: {
        filter_logic: "or",
        filters: { "0" => { field: "status", operator: "is", value: "complete" }, "1" => { field: "status", operator: "is", value: "withdrawn" } }
      }

      expect(document.css("[data-testid='table-filter-tokens'] .cs-filter-operation").map(&:text)).to eq([ "or" ])
      expect(match_count).to eq("3 matches")
    end

    it "renders the no-match state when the panel filters leave nothing" do
      get table_admin_event_participants_path(event), params: {
        sort: "email", direction: "desc",
        filters: { "0" => { field: "email", operator: "equals", value: "nobody@example.com" } }
      }

      empty = document.at_css("[data-testid='filter-no-match']")
      expect(empty.at_css(".cs-empty-title").text).to eq("No matches")
      expect(empty.at_css("a.cs-btn").text).to eq("Clear filters")
      expect(empty.at_css("a.cs-btn")["href"]).to eq(table_admin_event_participants_path(event, sort: "email", direction: "desc"))
    end

    it "renders a hidden client-side no-match row and a hidden count when unfiltered" do
      get table_admin_event_participants_path(event)

      expect(document.at_css("tr[data-data-table-target='noMatch']")["class"]).to include("hidden")
      expect(document.at_css("tr[data-data-table-target='noMatch'] button[data-action='data-table#clearSearch']").text).to eq("Clear filters")
      count = document.at_css("[data-data-table-target='count']")
      expect(count).to have_attribute("hidden")
      expect(count["data-server-filtered"]).to eq("false")
    end
  end

  describe "the travel calendar" do
    before { event.update!(groups_enabled: true) }

    it "renders a live property filter over the existing controls" do
      Travel.create!(participant_event: ada, mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 17))
      create(:group, event: event, name: "Otter group")

      get admin_event_travel_path(event)

      root = document.at_css("[data-controller~='cs-property-filter']")
      expect(root["data-controller"].split).to include("travel-calendar-filter", "cs-property-filter")
      expect(root["data-cs-property-filter-live-value"]).to eq("true")
      expect(root.at_css("input[role='combobox']")["placeholder"]).to eq("Find journeys")
      labels = root.css("select[data-cs-property-filter-target='property']").map { |select| select["data-cs-property-filter-label"] }
      expect(labels).to eq(%w[Direction Mode Pickup Group])
      expect(root.at_css("input[data-travel-calendar-filter-target='search'][data-cs-property-filter-target='text']")).to be_present

      empty = document.at_css("[data-testid='filter-no-match']")
      expect(empty).to have_attribute("hidden")
      expect(empty["data-travel-calendar-filter-target"]).to eq("empty")
      expect(empty.at_css(".cs-empty-title").text).to eq("No matches")
      expect(empty.at_css("button[data-action='cs-property-filter#clear']").text).to eq("Clear filters")
    end
  end

  describe "the original admin" do
    before { admin.update!(admin_console_beta: false) }

    it "still renders its own filter bar without console tokens" do
      get admin_event_participants_path(event), params: { status: "complete" }

      expect(document.at_css("[data-controller~='cs-property-filter']")).to be_nil
      expect(document.at_css("[data-testid='participant-filter-tokens']")).to be_nil
      expect(document.at_css("select[name='status']")).to be_present
      expect(document.at_css("input[name='search']")).to be_present
      expect(response.body).to include("Ada")
      expect(response.body).not_to include("Bram")
    end
  end
end
