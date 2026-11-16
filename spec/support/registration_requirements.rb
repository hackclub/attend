# A registration's status follows its requirements, and saving any record
# those read re-derives it. So a spec can't declare one complete and then
# touch its travel: it would be reopened for everything it never had.
#
# - complete_registration(pe) gives a registration everything it needs and
#   lets it become complete; meet_registration_requirements(pe, except:)
#   stops short of whatever the spec is about.
# - A group tagged `fiat_registrations: true` opts out instead: statuses are
#   whatever the spec sets and nothing re-derives them. For specs about
#   something else entirely (travel calendars, exports, scans) that only
#   need a registration to *be* complete.
module RegistrationRequirementsHelpers
  # Fills in whatever the registration is missing, without changing its
  # status. except: requirement keys to leave unmet, e.g. %w[waiver].
  def meet_registration_requirements(participant_event, except: [])
    except = Array(except).map(&:to_s)

    SyncsRegistration.suspended do
      Registration::Requirements.new(participant_event).unmet.each do |requirement|
        next if except.include?(requirement.key)

        RegistrationRequirementsHelpers.meet(participant_event, requirement.key)
      end
    end

    # reload leaves the record's memoised requirements behind
    participant_event.reload.reset_document_memoisation!
  end

  # Meets every requirement (bar `except`) and lets the status follow, quietly:
  # a registration that is complete because it has everything.
  def complete_registration(participant_event, except: [])
    meet_registration_requirements(participant_event, except: except)
    participant_event.sync_status!(cause: :requirements_met, notify: false)
    # reload leaves the record's memoised requirements behind
    participant_event.reload.reset_document_memoisation!
  end

  ANSWERS = %w[travel accommodation health emergency_contacts].freeze

  # Just the answers the participant fills in themselves (travel, health,
  # contacts), for specs about what happens once those are in.
  def fill_in_registration_answers(participant_event)
    SyncsRegistration.suspended do
      Registration::Requirements.new(participant_event).unmet.each do |requirement|
        RegistrationRequirementsHelpers.meet(participant_event, requirement.key) if ANSWERS.include?(requirement.key)
      end
    end

    # reload leaves the record's memoised requirements behind
    participant_event.reload.reset_document_memoisation!
  end

  def self.meet(participant_event, key)
    case key
    when "travel"
      %w[inbound outbound].each do |direction|
        participant_event.travels.find_or_create_by!(direction: direction) { |travel| travel.mode = "car" }
      end
    when "accommodation" then participant_event.accommodation || participant_event.create_accommodation!
    when "health"
      participant_event.medical || participant_event.create_medical!
      participant_event.dietary || participant_event.create_dietary!
      participant_event.accessibility || participant_event.create_accessibility!
    when "code_of_conduct" then participant_event.update_columns(code_of_conduct_accepted_at: Time.current)
    when "emergency_contacts" then participant_event.emergency_contacts.create!(name: "Ada Example", phone: "+14155550123")
    when "guardian_details", "guardian_portal"
      links = participant_event.guardian_participant_events
      if links.any?
        links.each { |link| link.update_columns(status: "completed", completed_at: Time.current) }
      else
        FactoryBot.create(:guardian_participant_event, participant_event: participant_event,
          status: :completed, completed_at: Time.current)
      end
    when "waiver", "freedom_waiver"
      consent = participant_event.consents.find_by(consent_type: key)
      if consent
        consent.update_columns(status: "signed", signed_at: Time.current)
      else
        FactoryBot.create(:consent, :signed, participant_event: participant_event, consent_type: key)
      end
    end
  end
end

RSpec.configure do |config|
  config.include RegistrationRequirementsHelpers

  config.around(:each, :fiat_registrations) do |example|
    SyncsRegistration.suspended { example.run }
  end
end
