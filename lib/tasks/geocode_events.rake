namespace :events do
  desc "Geocode events that have a city but no coordinates (dry run unless APPLY=1)"
  task geocode_missing: :environment do
    apply = ENV["APPLY"] == "1"
    # Events only geocode themselves when their address changes, so anything
    # imported or created before that callback existed sits on the map's floor
    # with no pin. This walks those rows once.
    scope = Event.where(location_latitude: nil).where.not(location_city: [ nil, "" ])
    resolved = 0
    failed = 0

    scope.find_each do |event|
      address = event.send(:geocode_address_string)
      puts "#{event.slug}: #{address}"
      next unless apply

      event.send(:geocode_location)
      if event.reload.location_latitude.present?
        resolved += 1
      else
        failed += 1
        puts "  no result"
      end
      # geocoder.hackclub.com is shared infrastructure; be a polite client.
      sleep 0.25
    end

    puts "\n#{scope.count} event(s) without coordinates."
    if apply
      puts "Resolved #{resolved}, unresolved #{failed}."
      Rails.cache.delete(LandingStats::CACHE_KEY)
    else
      puts "Dry run — re-run with APPLY=1 to geocode."
    end
  end
end
