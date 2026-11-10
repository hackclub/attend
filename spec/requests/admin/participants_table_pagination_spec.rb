require "rails_helper"

# The participants table renders one page at a time: rendering every row of a
# large event was the slow part. Search, filters, sort and grouping all still
# apply to the whole event, before the page is cut.
RSpec.describe "Admin participants table pagination", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:admin) do
    User.create!(email: "table-pages@example.com", name: "Table Pages", global_role: "global_admin", admin_console_beta: false)
  end

  # Last names sort Ashgrove..Ebberly; statuses alternate so grouping splits.
  let!(:rows) do
    [
      [ "Ashgrove", :withdrawn ], [ "Brackwell", :in_progress ], [ "Corrifax", :withdrawn ],
      [ "Dunmere", :in_progress ], [ "Ebberly", :withdrawn ]
    ].map do |last_name, status|
      create(:participant_event, event: event, status: status,
        participant: create(:participant, legal_first_name: "Pat", legal_last_name: last_name,
          email: "#{last_name.downcase}@example.com"))
    end
  end

  before { stub_const("Admin::ParticipantsController::TABLE_PER_PAGE", 2) }

  def document
    Nokogiri::HTML(response.body)
  end

  def listed_last_names
    document.css("tr[data-searchable] td[data-column='last_name']").map { |td| td.text.strip }
  end

  def pagination_text
    document.at_css("[data-testid='table-pagination']")&.text&.squish
  end

  def link_query(rel)
    href = document.at_css("[data-testid='table-pagination'] a[rel='#{rel}']")&.[]("href")
    href && Rack::Utils.parse_nested_query(URI.parse(href).query)
  end

  def each_admin_ui
    [ false, true ].each do |console|
      admin.update!(admin_console_beta: console)
      sign_in admin
      yield console
    end
  end

  it "renders one page of the sorted rows and links to the next with the view's params" do
    each_admin_ui do |console|
      get table_admin_event_participants_path(event), params: { group_by: "none", sort: "legal_last_name", direction: "desc" }

      expect(listed_last_names).to eq(%w[Ebberly Dunmere]), "console=#{console}"
      expect(pagination_text).to include("Showing 1 to 2 of 5 participants")
      expect(link_query("next")).to eq("group_by" => "none", "sort" => "legal_last_name", "direction" => "desc", "page" => "2")
      expect(link_query("prev")).to be_nil

      get table_admin_event_participants_path(event), params: { group_by: "none", sort: "legal_last_name", direction: "desc", page: 3 }

      expect(listed_last_names).to eq(%w[Ashgrove])
      expect(pagination_text).to include("Showing 5 to 5 of 5 participants")
      expect(link_query("prev")["page"]).to eq("2")
      expect(link_query("next")).to be_nil
    end
  end

  it "counts the whole event in the header, not the page" do
    each_admin_ui do |console|
      get table_admin_event_participants_path(event), params: { group_by: "none" }

      expect(document.text.squish).to include("5 total"), "console=#{console}"
    end
  end

  it "clamps a page past the end to the last page" do
    each_admin_ui do
      get table_admin_event_participants_path(event), params: { group_by: "none", page: 99 }

      expect(listed_last_names).to eq(%w[Ebberly])
    end
  end

  it "applies panel filters before paging" do
    each_admin_ui do |console|
      get table_admin_event_participants_path(event), params: {
        group_by: "none",
        filters: { "0" => { field: "status", operator: "is", value: "withdrawn" } }
      }

      expect(listed_last_names).to eq(%w[Ashgrove Corrifax])
      expect(pagination_text).to include("of 3 participants")
      expect(document.at_css("[data-testid='filter-match-count']").text.strip).to eq("3 matches") if console
      expect(link_query("next")["filters"]).to eq("0" => { "field" => "status", "operator" => "is", "value" => "withdrawn" })
    end
  end

  it "searches names and emails across every page, keeping the view's params in the form" do
    each_admin_ui do |console|
      get table_admin_event_participants_path(event), params: { group_by: "none", sort: "email", search: "ebber", page: 2 }

      expect(listed_last_names).to eq(%w[Ebberly]), "console=#{console}"
      expect(pagination_text).to be_nil

      form = document.css("form").find { |f| f.at_css("input[name='search']") }
      expect(form["method"]).to eq("get")
      expect(form.at_css("input[name='search']")["value"]).to eq("ebber")
      hidden = form.css("input[type='hidden']").to_h { |input| [ input["name"], input["value"] ] }
      expect(hidden).to eq("group_by" => "none", "sort" => "email")
    end
  end

  it "shows the search as a removable token in the console" do
    admin.update!(admin_console_beta: true)
    sign_in admin

    get table_admin_event_participants_path(event), params: { search: "<b>ebber</b>" }

    expect(response.body).not_to include("<b>ebber</b>")
    tokens = document.css("[data-testid='table-filter-tokens'] .cs-filter-token-text").map { |token| token.text.squish }
    expect(tokens).to eq([ "Name or email contains “<b>ebber</b>”" ])
    expect(document.at_css("[data-testid='filter-no-match']")).to be_present
  end

  it "groups the whole event, then pages through the grouped rows with whole-group counts" do
    each_admin_ui do |console|
      get table_admin_event_participants_path(event), params: { group_by: "status" }

      headers = document.css("tr[data-group-id] td").map { |td| td.text.squish }
      expect(headers).to eq([ "Withdrawn (3) 2 on this page" ]), "console=#{console}"
      expect(listed_last_names).to eq(%w[Ashgrove Corrifax])

      get table_admin_event_participants_path(event), params: { group_by: "status", page: 2 }

      headers = document.css("tr[data-group-id] td").map { |td| td.text.squish }
      expect(headers).to eq([ "Withdrawn (3) 1 on this page", "Awaiting Participant (2) 1 on this page" ])
      expect(listed_last_names).to eq(%w[Ebberly Brackwell])
    end
  end

  it "shows no pagination when everything fits on one page" do
    stub_const("Admin::ParticipantsController::TABLE_PER_PAGE", 100)

    each_admin_ui do
      get table_admin_event_participants_path(event), params: { group_by: "none" }

      expect(listed_last_names.size).to eq(5)
      expect(pagination_text).to be_nil
      expect(document.at_css("input[data-action*='selectAll']")["aria-label"]).to eq("Select all")
    end
  end
end
