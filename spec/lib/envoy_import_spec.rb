require "rails_helper"
require "rake"

# Envoy's tables live in a schema of their own in the test database, reached
# through a second connection like the real import's. Rows written there
# commit, so they're set up once and the schema is dropped afterwards; what
# the import writes to Attend rolls back with each example as usual.
module EnvoyImportSpec
  SCHEMA = "envoy_import_spec".freeze

  # Stands in for Envoy's R2 bucket.
  class FakeBucket
    def initialize(files) = @files = files

    def read(key) = @files.fetch(key)

    def exists?(key) = @files.key?(key)
  end

  LETTER = "%PDF-1.4 a fictional letter".b
  SIGNATURE = File.binread(Rails.root.join("spec/fixtures/files/headshot.png"))

  LETTER_SENT_ID = "00000000-0000-4000-8000-000000000001".freeze
  PENDING_ID = "00000000-0000-4000-8000-000000000002".freeze
  REJECTED_ID = "00000000-0000-4000-8000-000000000003".freeze
  UNVERIFIED_ID = "00000000-0000-4000-8000-000000000004".freeze
  APPROVED_ID = "00000000-0000-4000-8000-000000000005".freeze
  DEFAULT_TEMPLATE_ID = "00000000-0000-4000-8000-000000000011".freeze
  EVENT_TEMPLATE_ID = "00000000-0000-4000-8000-000000000012".freeze

  # Envoy's db/schema.rb, cut down to the tables and columns the import reads.
  def self.create_schema(connection)
    connection.create_table :admins, id: :uuid do |t|
      t.string :email, null: false
      t.string :first_name, null: false
      t.string :last_name, null: false
      t.timestamps
    end
    connection.create_table :events, id: :uuid do |t|
      t.uuid :admin_id, null: false
      t.string :name, :slug, :venue_name, :venue_address, :city, :country, :contact_email, null: false
      t.date :start_date, :end_date, null: false
      t.jsonb :rejection_reason_templates, default: [], null: false
      t.timestamps
    end
    connection.create_table :event_admins, id: :uuid do |t|
      t.uuid :admin_id, :event_id, null: false
      t.timestamps
    end
    connection.create_table :letter_templates, id: :uuid do |t|
      t.uuid :event_id
      t.boolean :active, default: true, null: false
      t.boolean :is_default, default: false, null: false
      t.string :name, :signatory_name, :signatory_title, null: false
      t.text :body, null: false
      t.timestamps
    end
    connection.create_table :participants, id: :uuid do |t|
      t.string :full_name, :email, :country_of_birth, :phone_number, null: false
      t.string :place_of_birth
      t.date :date_of_birth, null: false
      t.text :full_street_address, null: false
      t.timestamps
    end
    connection.create_table :visa_letter_applications, id: :uuid do |t|
      t.uuid :event_id, :participant_id, null: false
      t.uuid :reviewed_by_id
      t.string :status, default: "pending_verification", null: false
      t.string :reference_number, null: false
      t.string :verification_code, :rejection_type
      t.text :rejection_reason, :admin_notes
      t.jsonb :pending_participant_attributes
      t.datetime :submitted_at, :reviewed_at, :letter_generated_at, :letter_sent_at
      t.timestamps
    end
    connection.create_table :manual_invitations, id: :uuid do |t|
      t.uuid :admin_id, :event_id, null: false
      t.uuid :visa_letter_application_id
      t.string :email, :token, null: false
      t.datetime :claimed_at
      t.timestamps
    end
    connection.create_table :active_storage_blobs, id: :uuid do |t|
      t.string :key, :filename, :service_name, null: false
      t.string :content_type, :checksum
      t.text :metadata
      t.bigint :byte_size, null: false
      t.datetime :created_at, null: false
    end
    connection.create_table :active_storage_attachments, id: :uuid do |t|
      t.string :name, :record_type, null: false
      t.uuid :record_id, :blob_id, null: false
      t.datetime :created_at, null: false
    end
  end

  # Fictional people and events only: this repository is public.
  def self.seed(envoy)
    organiser = envoy[:admins].create!(email: "Organiser@example.com", first_name: "Olive", last_name: "Organiser")
    helper = envoy[:admins].create!(email: "helper@example.com", first_name: "Hal", last_name: "Helper")

    fest = envoy[:events].create!(admin_id: organiser.id, name: "Fictional Fest 2025", slug: "fictional-fest-2025",
      venue_name: "Example Hall", venue_address: "2 Example Street", city: "Example City", country: "Exampleland",
      contact_email: "fest@hackclub.com", start_date: Date.new(2025, 6, 6), end_date: Date.new(2025, 6, 8),
      rejection_reason_templates: [ "The name doesn't match your passport." ])
    summit = envoy[:events].create!(admin_id: organiser.id, name: "Sample Summit", slug: "sample-summit",
      venue_name: "Sample Centre", venue_address: "3 Sample Way", city: "Sampleton", country: "Exampleland",
      contact_email: "summit@example.com", start_date: Date.new(2026, 11, 20), end_date: Date.new(2026, 11, 22),
      rejection_reason_templates: [ "Wrong event." ])
    envoy[:events].create!(admin_id: organiser.id, name: "Clash", slug: "clash", venue_name: "Clash Hall",
      venue_address: "4 Clash Road", city: "Example City", country: "Exampleland", contact_email: "clash@example.com",
      start_date: Date.new(2024, 1, 5), end_date: Date.new(2024, 1, 6))
    envoy[:event_admins].create!(admin_id: helper.id, event_id: fest.id)

    body = "To Whom It May Concern,\r\n\r\nThe <strong>Hack Foundation</strong> confirms that <em>{{participant_full_name}}</em> " \
      "has been invited to attend {{event_name}} from {{event_date_range}} in {{event_city}}, {{event_country}}.\r\n\r\n" \
      "Reference Number: {{reference_number}}"
    default = envoy[:templates].create!(id: DEFAULT_TEMPLATE_ID, name: "Default", body: body, is_default: true,
      signatory_name: "Fictional Signatory", signatory_title: "Executive Director")
    event_template = envoy[:templates].create!(id: EVENT_TEMPLATE_ID, event_id: fest.id, name: "Fest letter", body: body,
      signatory_name: "Fictional Signatory", signatory_title: "Executive Director")
    attach(envoy, record_type: "LetterTemplate", record_id: default.id, name: "letterhead_image", key: "letterhead-key", bytes: SIGNATURE, content_type: "image/png", filename: "letterhead.png")
    attach(envoy, record_type: "LetterTemplate", record_id: event_template.id, name: "signature_image", key: "signature-key", bytes: SIGNATURE, content_type: "image/png", filename: "signature.png")

    ada = envoy[:participants].create!(full_name: "Ada Example", email: "Ada.Example@example.com", date_of_birth: Date.new(2007, 2, 3),
      country_of_birth: "Exampleland", place_of_birth: "Example Town", phone_number: "+1 202 555 0123", full_street_address: "1 Sample Road\nExample City")
    others = %w[grace kim lee].map do |name|
      envoy[:participants].create!(full_name: "#{name.capitalize} Sample", email: "#{name}@example.com", date_of_birth: Date.new(2006, 5, 6),
        country_of_birth: "Exampleland", phone_number: "not a number", full_street_address: "5 Sample Road")
    end

    envoy[:applications].create!(id: LETTER_SENT_ID, event_id: fest.id, participant_id: ada.id, status: "letter_sent",
      reference_number: "HC-FICT0001", verification_code: "A" * 32, reviewed_by_id: organiser.id,
      submitted_at: Time.utc(2025, 4, 1, 12), reviewed_at: Time.utc(2025, 4, 2, 9), letter_generated_at: Time.utc(2025, 4, 2, 9, 1),
      letter_sent_at: Time.utc(2025, 4, 2, 9, 2), created_at: Time.utc(2025, 4, 1, 12), updated_at: Time.utc(2025, 4, 2, 9, 2))
    envoy[:applications].create!(id: PENDING_ID, event_id: summit.id, participant_id: others[0].id, status: "pending_approval",
      reference_number: "HC-FICT0002", verification_code: "B" * 32, submitted_at: Time.utc(2026, 9, 1))
    envoy[:applications].create!(id: REJECTED_ID, event_id: fest.id, participant_id: others[1].id, status: "rejected",
      reference_number: "HC-FICT0003", verification_code: "C" * 32, rejection_type: "hard", rejection_reason: "Duplicate application.",
      reviewed_by_id: helper.id, reviewed_at: Time.utc(2025, 4, 3))
    envoy[:applications].create!(id: UNVERIFIED_ID, event_id: fest.id, participant_id: others[2].id, status: "pending_verification",
      reference_number: "HC-FICT0004", verification_code: "D" * 32)
    envoy[:applications].create!(id: APPROVED_ID, event_id: summit.id, participant_id: others[2].id, status: "approved",
      reference_number: "HC-FICT0005", verification_code: "E" * 32, reviewed_by_id: organiser.id, reviewed_at: Time.utc(2026, 9, 2))
    attach(envoy, record_type: "VisaLetterApplication", record_id: LETTER_SENT_ID, name: "letter_pdf", key: "letter-key", bytes: LETTER,
      content_type: "application/pdf", filename: "visa_letter_HC-FICT0001.pdf")

    envoy[:invitations].create!(admin_id: organiser.id, event_id: summit.id, email: "invitee@example.com", token: "envoy-invitation-token")
    envoy[:invitations].create!(admin_id: organiser.id, event_id: summit.id, email: "claimed@example.com", token: "claimed-invitation-token",
      claimed_at: Time.utc(2026, 9, 1))
  end

  def self.attach(envoy, record_type:, record_id:, name:, key:, bytes:, content_type:, filename:)
    blob = envoy[:blobs].create!(key: key, filename: filename, content_type: content_type, service_name: "cloudflare_r2",
      byte_size: bytes.bytesize, checksum: Digest::MD5.base64digest(bytes), metadata: "{}")
    envoy[:attachments].create!(record_type: record_type, record_id: record_id, name: name, blob_id: blob.id)
  end
end

RSpec.describe EnvoyImport do
  before(:all) do
    ActiveRecord::Base.connection.execute("DROP SCHEMA IF EXISTS #{EnvoyImportSpec::SCHEMA} CASCADE; CREATE SCHEMA #{EnvoyImportSpec::SCHEMA}")
    @tables = described_class.source_tables(ActiveRecord::Base.connection_db_config.configuration_hash.merge(schema_search_path: EnvoyImportSpec::SCHEMA))
    EnvoyImportSpec.create_schema(@tables[:events].connection)
    EnvoyImportSpec.seed(@tables)
  end

  after(:all) do
    @tables[:events].superclass.remove_connection
    ActiveRecord::Base.connection.execute("DROP SCHEMA IF EXISTS #{EnvoyImportSpec::SCHEMA} CASCADE")
  end

  let(:log) { StringIO.new }
  let!(:attend_event) { create(:event, name: "Sample Summit", slug: "sample-summit-2026") }
  let!(:organiser) { create(:user, email: "organiser@example.com") }
  let!(:applicant) { create(:user, email: "ada.example@example.com", hack_club_account_id: "ident!fictional-ada") }
  let!(:clashing_event) { create(:event, name: "Someone else's event", slug: "clash") }

  def run_import(apply:, storage: EnvoyImportSpec::FakeBucket.new("letter-key" => EnvoyImportSpec::LETTER, "signature-key" => EnvoyImportSpec::SIGNATURE), event_map: { "sample-summit" => "sample-summit-2026" })
    described_class.new(tables: @tables, apply: apply, event_map: event_map, storage: storage, out: log).run
  end

  it "only counts on a dry run" do
    expect { run_import(apply: false) }.not_to change { [ Event.count, VisaLetterApplication.count, VisaLetterTemplate.count, VisaLetterInvitation.count, EventRoleAssignment.count ] }

    expect(log.string).to include("Applications: would import 1 pending, 1 approved, 1 rejected, 1 letter sent")
    expect(log.string).to include("1 letter PDF(s) to copy")
    expect(log.string).to include("Dry run")
  end

  it "checks Envoy's bucket has each file on a dry run" do
    run_import(apply: false, storage: EnvoyImportSpec::FakeBucket.new("signature-key" => EnvoyImportSpec::SIGNATURE))

    expect(log.string).to include("Application HC-FICT0001's letter: missing from Envoy's bucket")
    expect(log.string).not_to include("signature: missing")
  end

  it "brings an unmapped event in as a finished event that doesn't count as Attend's" do
    run_import(apply: true)

    event = Event.find_by!(slug: "fictional-fest-2025")
    expect(event).to have_attributes(name: "Fictional Fest 2025", timezone: "UTC", location_city: "Example City",
      location_country: "Exampleland", support_email: "fest@hackclub.com", legacy_envoy_slug: "fictional-fest-2025",
      visa_letters_mode: "off", visa_letter_rejection_reasons_list: [ "The name doesn't match your passport." ])
    expect(event.config["imported_from"]).to eq("envoy")
    expect(event.starts_at).to eq(Time.utc(2025, 6, 6))
    expect(event.ends_at).to be_within(1.second).of(Time.utc(2025, 6, 8, 23, 59, 59))
    expect(event.setup_completed_at).to be_present
    expect(Event.not_imported).not_to include(event)

    expect(Event.find_by!(slug: "clash-envoy")).to have_attributes(support_email: nil, legacy_envoy_slug: "clash")
    expect(clashing_event.reload.legacy_envoy_slug).to be_nil
    expect(log.string).to include("map it with ENVOY_EVENT_MAP")
  end

  it "links a mapped event to Attend's without creating another" do
    run_import(apply: true)

    expect(attend_event.reload).to have_attributes(legacy_envoy_slug: "sample-summit", visa_letter_rejection_reasons_list: [ "Wrong event." ])
    expect(Event.where(name: "Sample Summit").count).to eq(1)
  end

  it "keeps a sent letter's identifiers and frozen details, and copies its PDF byte for byte" do
    run_import(apply: true)

    letter = VisaLetterApplication.find(EnvoyImportSpec::LETTER_SENT_ID)
    expect(letter).to have_attributes(
      status: "letter_sent", reference_number: "HC-FICT0001", verification_code: "A" * 32, imported?: true,
      full_name: "Ada Example", email: "ada.example@example.com", date_of_birth: Date.new(2007, 2, 3),
      nationality: "Exampleland", place_of_birth: "Example Town", phone: "+12025550123",
      address: "1 Sample Road\nExample City", user: applicant, reviewed_by: organiser,
      letter_event_name: "Fictional Fest 2025", letter_venue: "Example Hall", letter_address: "2 Example Street",
      letter_city: "Example City", letter_country: "Exampleland", letter_starts_on: Date.new(2025, 6, 6),
      letter_ends_on: Date.new(2025, 6, 8), letter_issued_on: Date.new(2025, 4, 2)
    )
    expect(letter.created_at).to eq(Time.utc(2025, 4, 1, 12))
    expect(letter.letter_pdf.download).to eq(EnvoyImportSpec::LETTER)
    expect(letter.letter_pdf.filename.to_s).to eq("visa_letter_HC-FICT0001.pdf")
  end

  it "maps the other statuses, keeps rejections and leaves unverified applications behind" do
    run_import(apply: true)

    expect(VisaLetterApplication.find(EnvoyImportSpec::PENDING_ID)).to have_attributes(status: "pending", user: nil, event: attend_event)
    expect(VisaLetterApplication.find(EnvoyImportSpec::REJECTED_ID)).to have_attributes(status: "rejected", rejection_type: "hard",
      rejection_reason: "Duplicate application.")
    expect(VisaLetterApplication.find(EnvoyImportSpec::APPROVED_ID)).to be_approved
    expect(VisaLetterApplication.exists?(EnvoyImportSpec::UNVERIFIED_ID)).to be(false)
    expect(log.string).to include("1 never verified, left behind")
    expect(log.string).to include("1 approved in Envoy without a letter")
  end

  it "copies templates with their signatures, and the unclaimed invitations" do
    run_import(apply: true)

    default = VisaLetterTemplate.find(EnvoyImportSpec::DEFAULT_TEMPLATE_ID)
    expect(default).to have_attributes(is_default: true, event: nil, signatory_name: "Fictional Signatory")
    expect(default.body).to include("To Whom It May Concern,\n\nThe <b>Hack Foundation</b> confirms that <i>{{participant_full_name}}</i>")
    expect(default.body).not_to include("\r")
    expect(log.string).to include("letterhead image isn't carried over")

    event_template = VisaLetterTemplate.find(EnvoyImportSpec::EVENT_TEMPLATE_ID)
    expect(event_template.event.slug).to eq("fictional-fest-2025")
    expect(event_template.signature_image.download).to eq(EnvoyImportSpec::SIGNATURE)

    expect(VisaLetterInvitation.find_by!(token: "envoy-invitation-token")).to have_attributes(
      email: "invitee@example.com", event: attend_event, issued_by: organiser, claimed_at: nil)
    expect(VisaLetterInvitation.where(token: "claimed-invitation-token")).to be_empty
  end

  it "makes Envoy's event admins Attend's where they have an account, and reports the rest" do
    run_import(apply: true)

    imported_event = Event.find_by!(slug: "fictional-fest-2025")
    expect(EventRoleAssignment.find_by!(user: organiser, event: imported_event)).to be_event_admin
    expect(EventRoleAssignment.find_by!(user: organiser, event: attend_event)).to be_event_admin
    expect(log.string).to include("helper@example.com (fictional-fest-2025)")
  end

  it "can run again without duplicating anything, attaching a letter it couldn't copy before" do
    run_import(apply: true, storage: nil)
    expect(VisaLetterApplication.find(EnvoyImportSpec::LETTER_SENT_ID).letter_pdf).not_to be_attached
    expect(log.string).to include("not copied, since Envoy's bucket isn't configured")

    expect { run_import(apply: true) }.not_to change { [ Event.count, VisaLetterApplication.count, VisaLetterTemplate.count, VisaLetterInvitation.count, EventRoleAssignment.count ] }

    expect(VisaLetterApplication.find(EnvoyImportSpec::LETTER_SENT_ID).letter_pdf.download).to eq(EnvoyImportSpec::LETTER)
    expect(VisaLetterTemplate.find(EnvoyImportSpec::EVENT_TEMPLATE_ID).signature_image).to be_attached
  end

  it "won't attach a file that doesn't match Envoy's checksum" do
    run_import(apply: true, storage: EnvoyImportSpec::FakeBucket.new("letter-key" => "tampered".b, "signature-key" => EnvoyImportSpec::SIGNATURE))

    expect(VisaLetterApplication.find(EnvoyImportSpec::LETTER_SENT_ID).letter_pdf).not_to be_attached
    expect(log.string).to include("doesn't match its checksum")
  end

  it "runs from the rake task, refusing to write without Envoy's bucket" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("envoy:import")
    allow(described_class).to receive(:source_tables).and_return(@tables)

    env = { "ENVOY_DATABASE_URL" => "postgres://envoy.invalid/envoy", "ENVOY_EVENT_MAP" => "sample-summit:sample-summit-2026" }
    stub_const("ENV", ENV.to_h.merge(env).except(*EnvoyImport::R2Storage::VARIABLES))
    expect { Rake::Task["envoy:import"].execute }.to output(/would import 1 pending, 1 approved, 1 rejected, 1 letter sent/).to_stdout

    stub_const("ENV", ENV.to_h.merge("APPLY" => "1"))
    expect {
      expect { Rake::Task["envoy:import"].execute }.to raise_error(SystemExit)
    }.to output(/APPLY=1 needs them/).to_stderr
  end

  describe ".template_body" do
    it "keeps paragraphs and turns Envoy's emphasis into the PDF's" do
      expect(described_class.template_body("One\r\n\r\n<STRONG class=\"x\">Two</strong> <em>three</em>"))
        .to eq("One\n\n<b>Two</b> <i>three</i>")
    end
  end
end
