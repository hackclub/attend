namespace :envoy do
  # One-shot migration off Envoy, the standalone visa letter app that owned
  # visas.hackclub.com before Attend took letters over. EnvoyImport
  # (lib/envoy_import.rb) says what comes across and how.
  #
  # ENVOY_EVENT_MAP links Envoy events to Attend events that already exist,
  # as comma-separated envoy-slug:attend-slug pairs; every other Envoy event
  # is brought in as a past event. ENVOY_R2_* is Envoy's Cloudflare R2
  # bucket, which holds the letter PDFs and signatures, read-only.
  #
  #   ENVOY_DATABASE_URL=postgres://... ENVOY_EVENT_MAP=envoy-slug:attend-slug rails envoy:import   # dry run
  #   ENVOY_DATABASE_URL=postgres://... ENVOY_EVENT_MAP=... \
  #     ENVOY_R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com ENVOY_R2_BUCKET=... \
  #     ENVOY_R2_ACCESS_KEY_ID=... ENVOY_R2_SECRET_ACCESS_KEY=... APPLY=1 rails envoy:import
  desc "Import Envoy's visa letters, events, templates, invitations and admins (dry run unless APPLY=1)"
  task import: :environment do
    database_url = ENV["ENVOY_DATABASE_URL"].presence
    abort "Set ENVOY_DATABASE_URL to Envoy's postgres connection string." if database_url.nil?

    apply = ENV["APPLY"] == "1"

    event_map = ENV["ENVOY_EVENT_MAP"].to_s.split(",").filter_map do |pair|
      envoy_slug, attend_slug = pair.split(":", 2).map(&:strip)
      abort "ENVOY_EVENT_MAP takes envoy-slug:attend-slug pairs; #{pair.inspect} isn't one." if envoy_slug.blank? || attend_slug.blank?

      [ envoy_slug, attend_slug ]
    end.to_h

    storage = EnvoyImport::R2Storage.from_env
    if storage.nil?
      abort "Set #{EnvoyImport::R2Storage::VARIABLES.join(", ")} to copy Envoy's letters; APPLY=1 needs them." if apply
      puts "Envoy's bucket isn't configured (#{EnvoyImport::R2Storage::VARIABLES.join(", ")}): files are counted, not checked.\n\n"
    end

    EnvoyImport.new(tables: EnvoyImport.source_tables(database_url), apply: apply, event_map: event_map, storage: storage).run
  end
end
