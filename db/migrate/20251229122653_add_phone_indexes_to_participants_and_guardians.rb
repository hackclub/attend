class AddPhoneIndexesToParticipantsAndGuardians < ActiveRecord::Migration[8.1]
  def change
    add_index :participants, :phone, where: "phone IS NOT NULL"
    add_index :guardians, :phone, where: "phone IS NOT NULL"
  end
end
