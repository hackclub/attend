require "rails_helper"

RSpec.describe Airtable::RecordsSync do
  let(:event) { create(:event, config: { "airtable_base_id" => "appTest" }) }
  let(:client) { Airtable::Client.new(api_key: "fictional-access", base_id: "appTest") }
  let(:columns) { Airtable::SyncService::SYNC_COLUMNS }
  let(:meta_url) { "https://api.airtable.com/v0/meta/bases/appTest/tables" }
  let(:records_url) { %r{\Ahttps://api\.airtable\.com/v0/appTest/tblOurs(\?.*)?\z} }

  subject(:sync) { described_class.new(event, client, request_interval: 0) }

  # Every column, with only the cells a spec cares about filled in.
  def row(id, **cells)
    columns.to_h { |column| [ column, nil ] }.merge(columns.first => id).merge(cells.transform_keys(&:to_s))
  end

  def airtable_record(record_id, fields)
    { id: record_id, fields: fields.compact }
  end

  def stub_tables(tables)
    stub_request(:get, meta_url).to_return(status: 200, body: { tables: tables }.to_json)
  end

  def stub_existing(records)
    stub_request(:get, records_url).to_return(status: 200, body: { records: records }.to_json)
  end

  before do
    stub_request(:patch, records_url).to_return(status: 200, body: { records: [] }.to_json)
    stub_request(:delete, records_url).to_return(status: 200, body: { records: [] }.to_json)
  end

  it "creates Attend's table on first sync and remembers it" do
    stub_tables([ { id: "tblSomeoneElses", name: "Planning", fields: [] } ])
    create_table = stub_request(:post, meta_url)
      .with { |req| body = JSON.parse(req.body); body["name"] == "Attend Participants" && body["fields"].first["name"] == "Participant Event ID" }
      .to_return(status: 200, body: { id: "tblOurs", name: "Attend Participants", fields: columns.map { |c| { name: c } } }.to_json)
    stub_existing([])

    result = sync.call("pe-1" => row("pe-1", "First Name" => "Ada"))

    expect(create_table).to have_been_requested
    expect(event.reload.airtable_sync_table_id).to eq("tblOurs")
    expect(result.written).to eq(1)
  end

  it "adds columns the table is missing" do
    stub_tables([ { id: "tblOurs", name: "Attend Participants", fields: columns.drop(1).map { |c| { name: c } } + [ { name: "Organiser notes" } ] } ])
    add_field = stub_request(:post, "#{meta_url}/tblOurs/fields")
      .with(body: { name: "Participant Event ID", type: "singleLineText" }.to_json)
      .to_return(status: 200, body: {}.to_json)
    stub_existing([])

    sync.call({})

    expect(add_field).to have_been_requested.once
  end

  it "writes only changed and new rows, and deletes rows for departed participants and duplicates" do
    event.update_columns(airtable_sync_table_id: "tblOurs")
    stub_tables([ { id: "tblOurs", name: "Renamed by an organiser", fields: columns.map { |c| { name: c } } } ])
    stub_existing([
      airtable_record("recSame", row("pe-same", "First Name" => "Ada")),
      airtable_record("recChanged", row("pe-changed", "First Name" => "Old")),
      airtable_record("recGone", row("pe-gone", "First Name" => "Grace")),
      airtable_record("recDuplicate", row("pe-same", "First Name" => "Ada")),
      # Added by hand in Airtable: no Participant Event ID, so not Attend's.
      airtable_record("recManual", { "First Name" => "Walk-in" })
    ])

    result = sync.call(
      "pe-same" => row("pe-same", "First Name" => "Ada"),
      "pe-changed" => row("pe-changed", "First Name" => "New"),
      "pe-new" => row("pe-new", "First Name" => "Linus")
    )

    expect(WebMock).to have_requested(:delete, records_url).with { |req|
      Rack::Utils.parse_nested_query(req.uri.query)["records"].sort == %w[recDuplicate recGone]
    }.once
    expect(WebMock).to have_requested(:patch, records_url).with { |req|
      body = JSON.parse(req.body)
      body["performUpsert"] == { "fieldsToMergeOn" => [ "Participant Event ID" ] } &&
        body["records"].map { |r| r.dig("fields", "Participant Event ID") } == %w[pe-changed pe-new]
    }.once
    expect(result).to have_attributes(written: 2, deleted: 2, unchanged: 1)
  end

  it "batches writes in tens" do
    event.update_columns(airtable_sync_table_id: "tblOurs")
    stub_tables([ { id: "tblOurs", name: "Attend Participants", fields: columns.map { |c| { name: c } } } ])
    stub_existing([])

    sync.call((1..23).to_h { |i| [ "pe-#{i}", row("pe-#{i}") ] })

    expect(WebMock).to have_requested(:patch, records_url).times(3)
  end

  it "makes no writes when Airtable already matches" do
    event.update_columns(airtable_sync_table_id: "tblOurs")
    stub_tables([ { id: "tblOurs", name: "Attend Participants", fields: columns.map { |c| { name: c } } } ])
    stub_existing([ airtable_record("recSame", row("pe-1", "Is Minor" => "false")) ])

    sync.call("pe-1" => row("pe-1", "Is Minor" => "false"))

    expect(WebMock).not_to have_requested(:patch, records_url)
    expect(WebMock).not_to have_requested(:delete, records_url)
  end
end
