class AddFollowUpReasonToRegistrationChangeRequests < ActiveRecord::Migration[8.1]
  def change
    # Set when Approve flags a request for staff itself, so the participant's
    # view can tell an automatic note from one staff wrote for them.
    add_column :registration_change_requests, :follow_up_reason, :string
  end
end
