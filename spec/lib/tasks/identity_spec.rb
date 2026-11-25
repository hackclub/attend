require "rails_helper"
require "rake"

RSpec.describe "identity rake tasks" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("identity:backfill") }

  def run(task, apply:)
    previous = ENV["APPLY"]
    ENV["APPLY"] = apply ? "1" : nil
    output = StringIO.new
    $stdout = output
    Rake::Task[task].execute
    output.string
  ensure
    $stdout = STDOUT
    ENV["APPLY"] = previous
  end

  # Nothing that could identify anyone: addresses, the names used below, ids.
  PERSONAL = /@|example|Robin|Alder|Morgan|Vale|[0-9a-f]{8}-[0-9a-f]{4}/

  describe "identity:normalize_emails" do
    let!(:participant) { store_legacy_email(create(:participant), " Robin.Vale@Example.com") }
    let!(:twin) { create(:participant, email: "robin.vale@example.com") }
    let!(:guardian) { store_legacy_email(create(:guardian), "Morgan.Vale@Example.com") }
    let!(:contact) do
      contact = EmergencyContact.create!(participant_event: create(:participant_event, participant: twin),
        name: "Alder Vale", phone: "+12025550143")
      store_legacy_email(contact, "Alder.Vale@Example.com")
    end
    let!(:untouched) { create(:participant, email: "already.fine@example.com") }

    it "only reports on a dry run" do
      output = run("identity:normalize_emails", apply: false)

      expect(participant.reload.email).to eq(" Robin.Vale@Example.com")
      expect(guardian.reload.email).to eq("Morgan.Vale@Example.com")
      expect(output).to include("dry run")
      expect(output).to match(/participants\n  would normalise: 1\n  of those, sharing their address with another row: 1/)
      expect(output).to match(/guardians\n  would normalise: 1\n  of those, sharing their address with another row: 0/)
      expect(output).not_to match(PERSONAL)
    end

    it "rewrites the stale rows with APPLY=1, including one that now matches another row exactly" do
      stamp = participant.updated_at

      output = nil
      expect { output = run("identity:normalize_emails", apply: true) }.not_to change(PaperTrail::Version, :count)

      expect(participant.reload.email).to eq("robin.vale@example.com")
      expect(participant.updated_at).to eq(stamp)
      expect(guardian.reload.email).to eq("morgan.vale@example.com")
      expect(contact.reload.email).to eq("alder.vale@example.com")
      expect(untouched.reload.email).to eq("already.fine@example.com")
      expect(output).to match(/participants\n  normalised: 1/)
      expect(output).not_to match(PERSONAL)
    end

    it "finds nothing to do the second time" do
      run("identity:normalize_emails", apply: true)

      expect(run("identity:normalize_emails", apply: true)).to match(/participants\n  normalised: 0/)
    end

    it "counts guardians sharing an address with their own participant without changing them" do
      registration = create(:participant_event, participant: participant)
      colliding = create(:guardian)
      create(:guardian_participant_event, guardian: colliding, participant_event: registration)
      store_legacy_email(colliding, "ROBIN.VALE@example.com")

      output = run("identity:normalize_emails", apply: false)

      expect(output).to include("guardians sharing an address with their own participant (not changed): 1")
    end
  end

  describe "identity:backfill" do
    before do
      create(:user, email: "robin.vale@example.com", hack_club_account_id: "ident!robin")
      create(:participant, email: "family@example.com", legal_first_name: "Robin", legal_last_name: "Vale")
      create(:participant, email: "family@example.com", legal_first_name: "Alder", legal_last_name: "Vale")
      create(:guardian, email: "morgan.vale@example.com", legal_first_name: "Morgan", legal_last_name: "Vale")
    end

    it "prints buckets of counts and writes nothing on a dry run" do
      output = nil
      expect { output = run("identity:backfill", apply: false) }.not_to change(Person, :count)

      expect(output).to include("MODE: dry run")
      expect(output).to include("person per account: 1")
      expect(output).to include("left for review:\n    same email flagged: 2")
      expect(output).to include("Dry run: nothing was written.")
      expect(output).not_to match(PERSONAL)
    end

    it "writes with APPLY=1, still printing counts only" do
      output = nil
      expect { output = run("identity:backfill", apply: true) }.to change(Person, :count).by(2)

      expect(output).to include("MODE: APPLY")
      expect(output).to include("Open identity reviews on file: 1")
      expect(output).not_to match(PERSONAL)
    end
  end
end
