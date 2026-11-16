require "rails_helper"

# A registration's status is only written by ParticipantEvent#transition_to!
# (and #reopen! / #mark_complete_if_eligible!, which go through it), so every
# change carries a cause. The model records anything that slips past as
# "untracked", but that's a safety net: this keeps new ones out of app code.
RSpec.describe "Registration status writers" do
  REGISTRATION = /(participant_event|registration|\bpe)\b[\w.&]*/
  RAW_WRITES = [
    /#{REGISTRATION}\.update(!|_columns?|_attribute)?\((.*[ ,(])?status:/,
    /#{REGISTRATION}\.(invited|in_progress|awaiting_guardian|complete|withdrawn|rejected)!/,
    /#{REGISTRATION}\.status\s*=[^=]/,
    /participant_events[\w.()&: ]*\.update_all\((.*[ ,(])?status:/
  ].freeze
  IGNORED = /guardian_participant_event|registration_change_request|visa_letter/

  it "has no raw status writes in app/ or lib/" do
    offenders = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake,erb}")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#") || line.match?(IGNORED)
        next unless RAW_WRITES.any? { |pattern| line.match?(pattern) }

        "#{Pathname(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, <<~MESSAGE
      These write a registration's status directly. Use
      ParticipantEvent#transition_to!(status, cause: ...) instead:

      #{offenders.join("\n")}
    MESSAGE
  end
end
