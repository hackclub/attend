class AddFailureReasonToConsents < ActiveRecord::Migration[8.1]
  def change
    add_column :consents, :failure_reason, :string
  end
end
