class AllowNullDateOfBirthOnParticipants < ActiveRecord::Migration[8.1]
  def change
    change_column_null :participants, :date_of_birth, true
  end
end
