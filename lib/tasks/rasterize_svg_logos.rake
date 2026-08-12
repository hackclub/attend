# One-off backfill: existing SVG logos render as broken images because
# ActiveStorage serves image/svg+xml as a binary download. New uploads are
# rasterized by the RasterizesSvgLogo concern; this converts old blobs.
#
# Usage: bin/rails logos:rasterize_svg
namespace :logos do
  desc "Rasterize existing SVG Event/EventSeries logos to PNG"
  task rasterize_svg: :environment do
    [ Event, EventSeries ].each do |klass|
      klass.find_each do |record|
        next unless record.logo.attached? && record.logo.content_type == RasterizesSvgLogo::SVG_CONTENT_TYPE

        begin
          svg = record.logo.download
          png = Vips::Image.thumbnail_buffer(svg, RasterizesSvgLogo::RASTER_WIDTH).write_to_buffer(".png")
          record.logo.attach(
            io: StringIO.new(png),
            filename: "#{record.logo.filename.base}.png",
            content_type: "image/png"
          )
          record.save!
          puts "rasterized #{klass.name} #{record.slug}"
        rescue Vips::Error, ActiveStorage::FileNotFoundError => e
          warn "FAILED #{klass.name} #{record.slug}: #{e.message}"
        end
      end
    end
  end
end
