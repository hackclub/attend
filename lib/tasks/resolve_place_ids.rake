namespace :events do
  desc "Look up Apple/Google place ids for venues that have a name and coordinates but no ids (dry run unless APPLY=1)"
  task resolve_place_ids: :environment do
    apply = ENV["APPLY"] == "1"
    scope = Event.where.not(venue_name: [ nil, "" ])
                 .where.not(location_latitude: nil)
                 .where("apple_place_id IS NULL OR google_place_id IS NULL")

    scope.find_each do |event|
      missing = %w[apple google].select { |p| event.public_send("#{p}_place_id").blank? }
      puts "#{event.slug}: #{event.venue_name} (missing #{missing.join(', ')})"
      next unless apply

      ResolveVenuePlaceIdsJob.perform_now(event.id)
      event.reload
      puts "  apple=#{event.apple_place_id || '-'} google=#{event.google_place_id || '-'}"
      sleep 0.25
    end

    puts "\n#{scope.count} event(s) still missing a place id." if apply
    puts "Dry run — re-run with APPLY=1 to resolve." unless apply
  end
end
