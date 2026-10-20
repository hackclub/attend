require "rails_helper"

RSpec.describe Airtable::RecordsSync do
  let(:event) { create(:event, config: { "airtable_base_id" => "appTest" }) }
  let(:client) { Airtable::Client.new(api_key: "fictional-access", base_id: "appTest") }
  let(:columns) { Airtable::SyncService::SYNC_COLUMNS }
  let(:meta_url) { "https://api.airtable.com/v0/meta/bases/appTest/tables" }
  let(:records_url) { %r{\Ahttps://api\.airtable\.com/v0/appTest/tblOurs(\?.*)?\z} }

  subject(:sync) { described_class.new(event, client, request_interval: 0) }

  let(:table_name) { described_class.table_name_for(event) }
  # Departed participants' ids look like real ones; only those get deleted.
  let(:same_id) { SecureRandom.uuid }
  let(:changed_id) { SecureRandom.uuid }
  let(:gone_id) { SecureRandom.uuid }
  let(:new_id) { SecureRandom.uuid }

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
      .with { |req| body = JSON.parse(req.body); body["name"] == table_name && body["fields"].first["name"] == "Participant Event ID" }
      .to_return(status: 200, body: { id: "tblOurs", name: table_name, fields: columns.map { |c| { name: c } } }.to_json)
    stub_existing([])

    result = sync.call("pe-1" => row("pe-1", "First Name" => "Ada"))

    expect(create_table).to have_been_requested
    expect(event.reload.airtable_sync_table_id).to eq("tblOurs")
    expect(result.written).to eq(1)
  end

  it "adds columns the table is missing" do
    stub_tables([ { id: "tblOurs", name: table_name, fields: columns.drop(1).map { |c| { name: c } } + [ { name: "Organiser notes" } ] } ])
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
      airtable_record("recSame", row(same_id, "First Name" => "Ada")),
      airtable_record("recChanged", row(changed_id, "First Name" => "Old")),
      airtable_record("recGone", row(gone_id, "First Name" => "Grace")),
      airtable_record("recDuplicate", row(same_id, "First Name" => "Ada")),
      # Added by hand in Airtable: no Participant Event ID, so not Attend's.
      airtable_record("recManual", { "First Name" => "Walk-in" })
    ])

    result = sync.call(
      same_id => row(same_id, "First Name" => "Ada"),
      changed_id => row(changed_id, "First Name" => "New"),
      new_id => row(new_id, "First Name" => "Linus")
    )

    expect(WebMock).to have_requested(:delete, records_url).with { |req|
      Rack::Utils.parse_nested_query(req.uri.query)["records"].sort == %w[recDuplicate recGone]
    }.once
    expect(WebMock).to have_requested(:patch, records_url).with { |req|
      body = JSON.parse(req.body)
      body["performUpsert"] == { "fieldsToMergeOn" => [ "Participant Event ID" ] } &&
        body["records"].map { |r| r.dig("fields", "Participant Event ID") } == [ changed_id, new_id ]
    }.once
    expect(result).to have_attributes(written: 2, deleted: 2, unchanged: 1)
  end

  it "batches writes in tens" do
    event.update_columns(airtable_sync_table_id: "tblOurs")
    stub_tables([ { id: "tblOurs", name: table_name, fields: columns.map { |c| { name: c } } } ])
    stub_existing([])

    sync.call((1..23).to_h { |i| [ "pe-#{i}", row("pe-#{i}") ] })

    expect(WebMock).to have_requested(:patch, records_url).times(3)
  end

  it "makes no writes when Airtable already matches" do
    event.update_columns(airtable_sync_table_id: "tblOurs")
    stub_tables([ { id: "tblOurs", name: table_name, fields: columns.map { |c| { name: c } } } ])
    stub_existing([ airtable_record("recSame", row(same_id, "Is Minor" => "false")) ])

    sync.call(same_id => row(same_id, "Is Minor" => "false"))

    expect(WebMock).not_to have_requested(:patch, records_url)
    expect(WebMock).not_to have_requested(:delete, records_url)
  end

  describe "keeping events out of each other's tables" do
    let(:other_event) { create(:event, airtable_sync_table_id: "tblTheirs", config: { "airtable_base_id" => "appTest" }) }

    it "never adopts a table another event syncs into, even by its stored id" do
      other_event
      event.update_columns(airtable_sync_table_id: "tblTheirs")
      stub_tables([ { id: "tblTheirs", name: described_class.table_name_for(other_event), fields: columns.map { |c| { name: c } } } ])
      create_table = stub_request(:post, meta_url)
        .to_return(status: 200, body: { id: "tblOurs", name: table_name, fields: columns.map { |c| { name: c } } }.to_json)
      stub_existing([])

      sync.call({})

      expect(create_table).to have_been_requested
      expect(event.reload.airtable_sync_table_id).to eq("tblOurs")
    end

    it "leaves rows alone that belong to another event or aren't participant ids" do
      event.update_columns(airtable_sync_table_id: "tblOurs")
      theirs = create(:participant_event, event: other_event)
      stub_tables([ { id: "tblOurs", name: table_name, fields: columns.map { |c| { name: c } } } ])
      stub_existing([
        airtable_record("recTheirs", row(theirs.id)),
        airtable_record("recTyped", row("typed by an organiser"))
      ])

      sync.call({})

      expect(WebMock).not_to have_requested(:delete, records_url)
    end
  end

  it "syncs real participants end to end through SyncService" do
    event.update_columns(airtable_sync_table_id: "tblOurs")
    event.create_airtable_connection!(access_token: "fictional-access", refresh_token: "fictional-refresh",
      access_token_expires_at: 1.hour.from_now, refresh_token_expires_at: 60.days.from_now)
    kept = create(:participant_event, event: event)
    departed_id = SecureRandom.uuid
    allow_any_instance_of(described_class).to receive(:sleep)
    stub_tables([ { id: "tblOurs", name: table_name, fields: columns.map { |c| { name: c } } } ])
    stub_existing([ airtable_record("recGone", row(departed_id)) ])

    result = Airtable::SyncService.new(event.reload).sync_via_records

    expect(WebMock).to have_requested(:delete, records_url).with(query: { "records" => [ "recGone" ] })
    expect(WebMock).to have_requested(:patch, records_url).with { |req|
      JSON.parse(req.body)["records"].map { |r| r.dig("fields", "Participant Event ID") } == [ kept.id ]
    }
    expect(result).to have_attributes(written: 1, deleted: 1)
  end
end
