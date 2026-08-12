class AddCodeOfConductToParticipantEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :participant_events, :code_of_conduct_accepted_at, :datetime
    add_column :participant_events, :code_of_conduct_signature, :string
  end
end
