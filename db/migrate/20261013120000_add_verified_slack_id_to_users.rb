class AddVerifiedSlackIdToUsers < ActiveRecord::Migration[8.1]
  # The Slack ID Hack Club Auth vouches for lives inside the encrypted
  # oidc_claims blob, so finding someone by it meant decrypting every
  # candidate in Ruby. A Slack ID isn't secret, so it gets its own plain,
  # indexed column, kept in step with the claims on every save.
  #
  # Schema only: this runs in every pod's entrypoint, so anything that can
  # raise here crash-loops the deploy. The index is built concurrently so it
  # doesn't lock users, and the backfill runs as a job instead.
  disable_ddl_transaction!

  def up
    add_column :users, :verified_slack_id, :string, if_not_exists: true
    add_index :users, :verified_slack_id, algorithm: :concurrently, if_not_exists: true

    enqueue_backfill
  end

  def down
    remove_column :users, :verified_slack_id
  end

  private

  # Delayed so the rolling deploy has finished before a worker picks it up: an
  # old-code worker doesn't know the job class and would fail it outright.
  # Failing to enqueue must never fail the migration; sign-ins heal rows
  # anyway, and `rails backfill:verified_slack_ids` reruns it.
  def enqueue_backfill
    BackfillVerifiedSlackIdsJob.set(wait: 15.minutes).perform_later
  rescue StandardError => e
    say "Could not enqueue BackfillVerifiedSlackIdsJob (#{e.class}: #{e.message}); run `rails backfill:verified_slack_ids` instead"
  end
end
