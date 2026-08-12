class AddDocusealHostToEventsAndConsents < ActiveRecord::Migration[8.1]
  def up
    add_column :events, :docuseal_host, :string
    add_column :consents, :docuseal_host, :string

    legacy_host = Docuseal::HostConfig.legacy_host
    say_with_time("Backfilling docuseal_host=#{legacy_host} on existing rows") do
      Event.where(docuseal_host: nil).update_all(docuseal_host: legacy_host)
      Consent.where(docuseal_host: nil).update_all(docuseal_host: legacy_host)
    end
  end

  def down
    remove_column :consents, :docuseal_host
    remove_column :events, :docuseal_host
  end
end
