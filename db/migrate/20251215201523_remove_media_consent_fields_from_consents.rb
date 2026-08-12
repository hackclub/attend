class RemoveMediaConsentFieldsFromConsents < ActiveRecord::Migration[8.1]
  def change
    remove_column :consents, :media_consent_granted, :boolean
    remove_column :consents, :media_public_use_granted, :boolean
  end
end
