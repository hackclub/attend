# The redirect links behind the QR codes printed on Hack Club event badges,
# moved here from badgekit — the standalone app that used to own
# badge.hackclub.com and made people sign in there separately to change them.
#
# Keyed by Slack ID rather than by user, because that's what the printed QR
# codes encode and it's all badgekit ever stored: a redirect has to keep
# resolving whether or not its owner has an Attend account. `user_id` is the
# link back once someone signs in and claims it, and nullifies so that
# deleting a user leaves the badge in their pocket still working.
class CreateBadgeRedirects < ActiveRecord::Migration[8.0]
  def change
    create_table :badge_redirects, id: :uuid do |t|
      t.string :slack_id, null: false
      t.string :url
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }, index: true

      t.timestamps
    end

    add_index :badge_redirects, :slack_id, unique: true
  end
end
