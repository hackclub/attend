require "rails_helper"
require "rake"

# The paths that keep a registration's status in line with its requirements
# without anyone asking: records it reads changing, the nightly drift check,
# and the backfill task.
RSpec.describe "Registration status sync" do
  let(:event) { create(:event, freedom_waivers_enabled: false) }
  let(:adult) { create(:participant, date_of_birth: 18.years.ago - 1.month) }
  let(:minor) { create(:participant, date_of_birth: 15.years.ago) }

  def complete_adult
    complete_registration(create(:participant_event, participant: adult, event: event))
  end

  describe "triggers" do
    it "follows a contact given by a guardian" do
      pe = complete_registration(create(:participant_event, participant: minor, event: event))
      link = pe.guardian_participant_events.sole
      contact = link.emergency_contacts.create!(name: "Ada Example", phone: "+14155550123")
      minor.update!(date_of_birth: 18.years.ago - 1.month)
      expect(pe.reload).to be_complete

      contact.destroy!

      expect(pe.reload).to be_in_progress
      expect(pe.registration_transitions.chronological.last.blocking_requirement).to eq("emergency_contacts")
    end

    it "follows the date of birth, which decides whether a guardian is needed" do
      pe = complete_adult

      adult.update!(date_of_birth: 15.years.ago)

      expect(pe.reload).to be_in_progress
      expect(pe.registration_transitions.chronological.last.blocking_requirement).to eq("guardian_details")
    end

    it "leaves the other registrations of a destroyed one's records alone" do
      pe = complete_adult

      expect { pe.destroy! }.not_to raise_error
    end

    it "does nothing for an event that has ended" do
      pe = complete_adult
      event.update_columns(starts_at: 3.days.ago, ends_at: 1.day.ago)

      pe.consents.first.update!(status: :sent)

      expect(pe.reload).to be_complete
    end
  end

  describe "drift" do
    # Rows from before statuses were derived: written straight to the column.
    let!(:stale_complete) do
      create(:participant_event, participant: adult, event: event).tap { |pe| pe.update_columns(status: "complete") }
    end
    let!(:stale_in_progress) do
      meet_registration_requirements(create(:participant_event, event: event, participant: create(:participant, date_of_birth: 18.years.ago - 2.months)))
    end
    let!(:in_step) { complete_registration(create(:participant_event, event: event, participant: create(:participant, date_of_birth: 18.years.ago - 2.months))) }
    let!(:ended) do
      past = create(:event, starts_at: 3.days.ago, ends_at: 1.day.ago)
      create(:participant_event, event: past).tap { |pe| pe.update_columns(status: "complete") }
    end

    it "finds the registrations whose status has fallen behind, at events that haven't ended" do
      expect(RegistrationDriftCheckJob.drifted).to contain_exactly(stale_complete, stale_in_progress)
    end

    it "reports without repairing" do
      expect(Rails.logger).to receive(:warn).with(a_string_including("2 registrations have drifted"))

      RegistrationDriftCheckJob.perform_now

      expect(stale_complete.reload).to be_complete
    end

    describe "rake registration:sync" do
      before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("registration:sync") }

      def run(**env)
        previous = ENV.to_h.slice("APPLY", "NOTIFY", "EVENT")
        %w[APPLY NOTIFY EVENT].each { |key| ENV.delete(key) }
        env.each { |key, value| ENV[key.to_s.upcase] = value }
        expect { Rake::Task["registration:sync"].execute }.to output.to_stdout
      ensure
        %w[APPLY NOTIFY EVENT].each { |key| ENV.delete(key) }
        previous.each { |key, value| ENV[key] = value }
      end

      it "only reports on a dry run" do
        run

        expect(stale_complete.reload).to be_complete
        expect(stale_in_progress.reload).to be_in_progress
      end

      it "brings them in line, quietly, and leaves ended events alone" do
        expect { run(apply: "1") }.not_to have_enqueued_mail(ParticipantMailer, :registration_confirmed)

        expect(stale_complete.reload).to be_in_progress
        expect(stale_in_progress.reload).to be_complete
        expect(stale_in_progress.registration_transitions.chronological.last.cause).to eq("backfill")
        expect(ended.reload).to be_complete
        expect(RegistrationDriftCheckJob.drifted).to be_empty
      end

      it "sends the usual emails when asked to" do
        expect { run(apply: "1", notify: "1") }.to have_enqueued_mail(ParticipantMailer, :registration_confirmed).once
      end
    end
  end
end
