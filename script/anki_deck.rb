# Builds an Anki deck (.apkg) of confirmed attendees for an event and uploads
# it to the app's active storage service (R2 in production), printing a signed
# download URL.
#
# Works in the prod console with zero extra gems: sqlite is driven through
# ruby's stdlib Fiddle against the system libsqlite3, and the zip comes from
# rubyzip (already in the bundle via passkit).
#
# Usage — paste this whole file into the rails console, then:
#
#   AnkiDeck.run!("event-slug")
#
# Or locally: bin/rails runner script/anki_deck.rb <event-slug>

require "fiddle"
require "json"
require "digest"
require "tmpdir"
require "zip"

module AnkiDeck
  module_function

  # --- minimal sqlite binding via Fiddle -------------------------------------

  def sqlite_lib
    @sqlite_lib ||= begin
      handle = nil
      %w[libsqlite3.so.0 libsqlite3.dylib libsqlite3.so].each do |name|
        handle = begin
          Fiddle.dlopen(name)
        rescue Fiddle::DLError
          nil
        end
        break if handle
      end
      raise "could not dlopen libsqlite3" unless handle
      handle
    end
  end

  def sqlite_fn(name, args, ret)
    Fiddle::Function.new(sqlite_lib[name.to_s], args, ret)
  end

  def sqlite_open(path)
    open_fn = sqlite_fn(:sqlite3_open, [ Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP ], Fiddle::TYPE_INT)
    pdb = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
    rc = open_fn.call(path, pdb)
    raise "sqlite3_open failed (rc=#{rc})" unless rc.zero?
    pdb.ptr
  end

  def sqlite_exec(db, sql)
    @exec_fn ||= sqlite_fn(:sqlite3_exec, [ Fiddle::TYPE_VOIDP ] * 5, Fiddle::TYPE_INT)
    @errmsg_fn ||= sqlite_fn(:sqlite3_errmsg, [ Fiddle::TYPE_VOIDP ], Fiddle::TYPE_VOIDP)
    rc = @exec_fn.call(db, sql, nil, nil, nil)
    raise "sqlite error (rc=#{rc}): #{Fiddle::Pointer.new(@errmsg_fn.call(db))} -- in: #{sql[0, 120]}" unless rc.zero?
  end

  def sqlite_close(db)
    sqlite_fn(:sqlite3_close, [ Fiddle::TYPE_VOIDP ], Fiddle::TYPE_INT).call(db)
  end

  def q(str)
    "'#{str.to_s.gsub("'", "''")}'"
  end

  # --- anki collection --------------------------------------------------------

  SCHEMA = <<~SQL
    CREATE TABLE col (id integer primary key, crt integer not null, mod integer not null,
      scm integer not null, ver integer not null, dty integer not null, usn integer not null,
      ls integer not null, conf text not null, models text not null, decks text not null,
      dconf text not null, tags text not null);
    CREATE TABLE notes (id integer primary key, guid text not null, mid integer not null,
      mod integer not null, usn integer not null, tags text not null, flds text not null,
      sfld integer not null, csum integer not null, flags integer not null, data text not null);
    CREATE TABLE cards (id integer primary key, nid integer not null, did integer not null,
      ord integer not null, mod integer not null, usn integer not null, type integer not null,
      queue integer not null, due integer not null, ivl integer not null, factor integer not null,
      reps integer not null, lapses integer not null, left integer not null, odue integer not null,
      odid integer not null, flags integer not null, data text not null);
    CREATE TABLE revlog (id integer primary key, cid integer not null, usn integer not null,
      ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null,
      time integer not null, type integer not null);
    CREATE TABLE graves (usn integer not null, oid integer not null, type integer not null);
    CREATE INDEX ix_notes_usn on notes (usn);
    CREATE INDEX ix_cards_usn on cards (usn);
    CREATE INDEX ix_revlog_usn on revlog (usn);
    CREATE INDEX ix_cards_nid on cards (nid);
    CREATE INDEX ix_cards_sched on cards (did, queue, due);
    CREATE INDEX ix_revlog_cid on revlog (cid);
    CREATE INDEX ix_notes_csum on notes (csum);
  SQL

  def stable_id(text)
    Digest::SHA1.hexdigest(text)[0, 15].to_i(16)
  end

  def model_json(model_id, deck_id)
    {
      model_id.to_s => {
        "css" => ".card { font-family: -apple-system, sans-serif; font-size: 20px; }\nimg { max-width: 320px; max-height: 320px; border-radius: 12px; }",
        "did" => deck_id, "id" => model_id.to_s, "name" => "Attendee (photo → name)",
        "flds" => %w[Photo Name Location].each_with_index.map { |n, i|
          { "name" => n, "ord" => i, "font" => "Liberation Sans", "media" => [], "rtl" => false, "size" => 20, "sticky" => false }
        },
        "tmpls" => [ {
          "name" => "Who is this?", "ord" => 0,
          "qfmt" => '<div style="text-align:center">{{Photo}}</div>',
          "afmt" => '{{FrontSide}}<hr id="answer"><div style="text-align:center;font-size:1.4em">{{Name}}</div><div style="text-align:center;color:#888">{{Location}}</div>',
          "bafmt" => "", "bqfmt" => "", "bfont" => "", "bsize" => 0, "did" => nil
        } ],
        "req" => [ [ 0, "all", [ 0 ] ] ], "sortf" => 0, "tags" => [], "type" => 0, "usn" => -1, "vers" => [],
        "latexPre" => "\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n\\begin{document}\n",
        "latexPost" => "\\end{document}", "latexsvg" => false,
        "mod" => Time.now.to_i
      }
    }
  end

  def decks_json(deck_id, deck_name)
    base = { "collapsed" => false, "conf" => 1, "desc" => "", "dyn" => 0, "extendNew" => 0,
             "extendRev" => 50, "lrnToday" => [ 0, 0 ], "newToday" => [ 0, 0 ],
             "revToday" => [ 0, 0 ], "timeToday" => [ 0, 0 ], "usn" => -1, "mod" => Time.now.to_i }
    {
      "1" => base.merge("id" => 1, "name" => "Default", "usn" => 0, "extendNew" => 10),
      deck_id.to_s => base.merge("id" => deck_id, "name" => deck_name)
    }
  end

  def conf_json(model_id)
    { "activeDecks" => [ 1 ], "addToCur" => true, "collapseTime" => 1200, "curDeck" => 1,
      "curModel" => model_id.to_s, "dueCounts" => true, "estTimes" => true, "newBury" => true,
      "newSpread" => 0, "nextPos" => 1, "sortBackwards" => false, "sortType" => "noteFld", "timeLim" => 0 }
  end

  def dconf_json
    { "1" => {
      "autoplay" => true, "id" => 1, "maxTaken" => 60, "mod" => 0, "name" => "Default",
      "replayq" => true, "timer" => 0, "usn" => 0,
      "lapse" => { "delays" => [ 10 ], "leechAction" => 0, "leechFails" => 8, "minInt" => 1, "mult" => 0 },
      "new" => { "bury" => true, "delays" => [ 1, 10 ], "initialFactor" => 2500, "ints" => [ 1, 4, 7 ],
                 "order" => 1, "perDay" => 20, "separate" => true },
      "rev" => { "bury" => true, "ease4" => 1.3, "fuzz" => 0.05, "ivlFct" => 1, "maxIvl" => 36500,
                 "minSpace" => 1, "perDay" => 100 }
    } }
  end

  def write_collection(db_path, deck_name, deck_key, cards)
    model_id = stable_id("attend-anki-model-v1")
    deck_id = stable_id("attend-anki-deck-#{deck_key}")
    now_s = Time.now.to_i
    now_ms = now_s * 1000

    db = sqlite_open(db_path)
    sqlite_exec(db, SCHEMA)
    sqlite_exec(db, <<~SQL)
      INSERT INTO col VALUES (1, #{now_s}, #{now_ms}, #{now_ms}, 11, 0, 0, 0,
        #{q(JSON.generate(conf_json(model_id)))},
        #{q(JSON.generate(model_json(model_id, deck_id)))},
        #{q(JSON.generate(decks_json(deck_id, deck_name)))},
        #{q(JSON.generate(dconf_json))}, '{}');
    SQL

    cards.each_with_index do |card, i|
      note_id = now_ms + (i * 2)
      card_id = note_id + 1
      guid = Digest::SHA1.hexdigest("attend-anki-guid-#{card[:id]}")[0, 10]
      flds = [ %(<img src="#{card[:image]}">), card[:name], card[:location] ].join("\x1f")
      sqlite_exec(db, <<~SQL)
        INSERT INTO notes VALUES (#{note_id}, #{q(guid)}, #{model_id}, #{now_s}, -1, '',
          #{q(flds)}, #{q(%(<img src="#{card[:image]}">))}, 0, 0, '');
        INSERT INTO cards VALUES (#{card_id}, #{note_id}, #{deck_id}, 0, #{now_s}, -1,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, '');
      SQL
    end

    sqlite_close(db)
  end

  # --- main ------------------------------------------------------------------

  def run!(slug)
    event = Event.find_by(slug: slug)
    raise "no event with slug #{slug.inspect} (have: #{Event.pluck(:slug).join(', ')})" unless event

    scope = event.participant_events.complete.includes(:participant)
    puts "#{event.name}: #{scope.count} confirmed (complete) attendees"

    Dir.mktmpdir("anki-deck") do |dir|
      cards = []
      skipped = []

      scope.find_each do |pe|
        p = pe.participant
        unless p.headshot.attached?
          skipped << "#{p.display_name} (no headshot)"
          next
        end

        ext = { "image/jpeg" => "jpg", "image/png" => "png", "image/webp" => "webp" }[p.headshot.content_type] || "jpg"
        filename = "attendee-#{p.id}.#{ext}"
        begin
          File.binwrite(File.join(dir, filename), p.headshot.download)
        rescue => e
          skipped << "#{p.display_name} (download failed: #{e.class}: #{e.message})"
          next
        end

        cards << {
          id: p.id,
          name: p.display_name,
          location: [ p.city, p.state, p.country_of_residence ].map(&:presence).compact.join(", "),
          image: filename
        }
        print "."
      end
      puts

      raise "no attendees with headshots — nothing to build" if cards.empty?

      db_path = File.join(dir, "collection.anki2")
      write_collection(db_path, "#{event.name} attendees", event.slug, cards)

      apkg_path = File.join(dir, "deck.apkg")
      Zip::File.open(apkg_path, create: true) do |zip|
        zip.add("collection.anki2", db_path)
        manifest = cards.each_with_index.to_h { |c, i| [ i.to_s, c[:image] ] }
        zip.get_output_stream("media") { |f| f.write(JSON.generate(manifest)) }
        cards.each_with_index { |c, i| zip.add(i.to_s, File.join(dir, c[:image])) }
      end

      blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open(apkg_path),
        filename: "#{event.slug}-attendees-#{Date.current}.apkg",
        content_type: "application/octet-stream"
      )

      url = begin
        blob.url(expires_in: 7.days)
      rescue ArgumentError, NoMethodError
        # Disk service (dev) needs url_options
        ActiveStorage::Current.url_options = { host: "localhost", port: 3000, protocol: "http" }
        blob.url(expires_in: 7.days)
      end

      puts
      puts "built deck with #{cards.size} cards (#{(File.size(apkg_path) / 1024.0 / 1024.0).round(1)} MB)"
      if skipped.any?
        puts "skipped #{skipped.size}:"
        skipped.each { |s| puts "  - #{s}" }
      end
      puts
      puts "download (valid 7 days):"
      puts url
      puts
      puts "cleanup later with: ActiveStorage::Blob.find_signed(#{blob.signed_id.inspect}).purge"

      { blob: blob, url: url, cards: cards.size, skipped: skipped }
    end
  end
end

AnkiDeck.run!(ARGV[0]) if !defined?(Rails::Console) && ARGV[0].to_s.strip != ""
