class RemoveUnusedAcknowledgementFlagsFromSafeguardingInfos < ActiveRecord::Migration[8.1]
  def change
    remove_column :safeguarding_infos, :curfew_acknowledged, :boolean, default: false
    remove_column :safeguarding_infos, :overnight_rules_acknowledged, :boolean, default: false
  end
end
