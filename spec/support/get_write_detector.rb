# Fails any example in which a GET or HEAD request wrote to the database
# outside config/get_write_allowlist.yml. See lib/middleware/get_write_detector.rb.
#
# Fixing the write is the right answer most of the time: move it to the POST
# that caused it, or to a job. When a GET really has to write, add it to the
# allowlist with the reason.
#
# An example that is about a GET write can opt out with `allow_get_writes: true`.
#
# GET_WRITE_REPORT=path/to/file runs the suite without failing and writes every
# GET write seen (allowlisted or not) to that file, for pruning the allowlist.
module GetWriteReport
  class << self
    def path
      ENV["GET_WRITE_REPORT"].presence
    end

    def seen
      @seen ||= Hash.new { |hash, endpoint| hash[endpoint] = { statements: Set.new, specs: Set.new, allowed: true } }
    end

    def add(write, example)
      entry = seen[write.endpoint]
      entry[:statements] << write.sql.squish.truncate(110)
      entry[:specs] << example.metadata[:file_path]
      entry[:allowed] &&= GetWriteDetector.allowlist.allowed?(write)
    end

    def dump
      lines = seen.sort.flat_map do |endpoint, entry|
        [ "#{entry[:allowed] ? 'allowed' : 'NEW    '}  #{endpoint}  (#{entry[:specs].sort.first(3).join(', ')})" ] +
          entry[:statements].sort.map { |statement| "           #{statement}" }
      end
      File.write(path, lines.join("\n") + "\n")
    end
  end
end

RSpec.configure do |config|
  config.before(:each) { GetWriteDetector.drain }

  config.after(:each) do |example|
    writes = GetWriteDetector.drain
    next if writes.empty?

    if GetWriteReport.path
      writes.each { |write| GetWriteReport.add(write, example) }
      next
    end

    next if example.metadata[:allow_get_writes]

    unexpected = writes.reject { |write| GetWriteDetector.allowlist.allowed?(write) }
    next if unexpected.empty?

    raise <<~MESSAGE
      A GET request wrote to the database outside config/get_write_allowlist.yml:

      #{unexpected.uniq { |write| [ write.endpoint, write.table ] }.map { |write| "  #{write}" }.join("\n")}

      Move the write to a non-GET request or a job, or add the action to the allowlist with its reason.
    MESSAGE
  end

  config.after(:suite) { GetWriteReport.dump if GetWriteReport.path }
end
