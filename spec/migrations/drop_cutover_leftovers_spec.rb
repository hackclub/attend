require "rails_helper"
require Rails.root.join("db/migrate/20261029200000_drop_cutover_leftovers")

RSpec.describe DropCutoverLeftovers do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }
  let(:connection) { ActiveRecord::Base.connection }

  # schema.rb no longer has them, so put back some of what a database loaded
  # from the cutover's schema.rb has
  before do
    connection.create_table(:nfc_tokens, id: :uuid) { |t| t.uuid :user_id }
    connection.create_table(:flipper_features) { |t| t.string :key }
    connection.add_column :participant_events, :totp_secret, :string
    connection.add_column :scan_contexts, :is_airport, :boolean, default: false, null: false
  end

  after { [ ParticipantEvent, ScanContext ].each(&:reset_column_information) }

  it "drops them when none of them hold data" do
    create(:participant_event) # with scan points left at is_airport's default

    migration.up

    expect(connection.table_exists?(:nfc_tokens)).to be(false)
    expect(connection.table_exists?(:flipper_features)).to be(false)
    expect(connection.column_exists?(:participant_events, :totp_secret)).to be(false)
    expect(connection.column_exists?(:scan_contexts, :is_airport)).to be(false)
  end

  it "drops nothing while a leftover table has rows" do
    connection.execute("INSERT INTO nfc_tokens (user_id) VALUES (gen_random_uuid())")

    expect { migration.up }.to raise_error(/nothing was dropped: nfc_tokens\./)

    expect(connection.table_exists?(:flipper_features)).to be(true)
    expect(connection.column_exists?(:participant_events, :totp_secret)).to be(true)
  end

  it "drops nothing while a leftover column holds data" do
    registration = create(:participant_event)
    connection.execute(ActiveRecord::Base.sanitize_sql([ "UPDATE participant_events SET totp_secret = 'fake' WHERE id = ?", registration.id ]))
    connection.execute("UPDATE scan_contexts SET is_airport = true")

    expect { migration.up }.to raise_error(/nothing was dropped: participant_events\.totp_secret, scan_contexts\.is_airport\./)

    expect(connection.table_exists?(:nfc_tokens)).to be(true)
  end
end
