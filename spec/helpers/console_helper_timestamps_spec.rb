require "rails_helper"

RSpec.describe ConsoleHelper, type: :helper do
  let(:now) { Time.utc(2026, 10, 12, 12, 0, 0) }

  describe "#cs_relative_time_text" do
    def past(duration) = helper.cs_relative_time_text(now - duration, now: now)
    def future(duration) = helper.cs_relative_time_text(now + duration, now: now)

    it "returns nil for nil" do
      expect(helper.cs_relative_time_text(nil, now: now)).to be_nil
    end

    it "says Now for anything under a minute, either side" do
      expect(past(0.seconds)).to eq("Now")
      expect(past(59.seconds)).to eq("Now")
      expect(future(59.seconds)).to eq("Now")
    end

    it "counts minutes from 1 to 59" do
      expect(past(60.seconds)).to eq("1 minute ago")
      expect(past(119.seconds)).to eq("1 minute ago")
      expect(past(2.minutes)).to eq("2 minutes ago")
      expect(past(36.minutes)).to eq("36 minutes ago")
      expect(past(59.minutes + 59.seconds)).to eq("59 minutes ago")
    end

    it "counts hours from 1 to 24" do
      expect(past(60.minutes)).to eq("1 hour ago")
      expect(past(2.hours)).to eq("2 hours ago")
      expect(past(24.hours)).to eq("24 hours ago")
      expect(past(24.hours + 59.minutes)).to eq("24 hours ago")
    end

    it "moves to days after 24 hours and counts up to 31" do
      expect(past(25.hours)).to eq("1 day ago")
      expect(past(2.days)).to eq("2 days ago")
      expect(past(31.days)).to eq("31 days ago")
    end

    it "moves to weeks after 31 days and counts up to 4" do
      expect(past(32.days)).to eq("4 weeks ago")
      expect(past(34.days)).to eq("4 weeks ago")
    end

    it "moves to months after 4 weeks and counts up to 12" do
      expect(past(35.days)).to eq("1 month ago")
      expect(past(61.days)).to eq("2 months ago")
      expect(past(364.days)).to eq("11 months ago")
      expect(past(12.months + 29.days)).to eq("12 months ago")
      expect(past(12.months)).to eq("12 months ago")
    end

    it "moves to years after 12 months" do
      expect(past(13.months)).to eq("1 year ago")
      expect(past(2.years)).to eq("2 years ago")
      expect(past(10.years)).to eq("10 years ago")
    end

    it "phrases future times with In and the same units" do
      expect(future(1.minute)).to eq("In 1 minute")
      expect(future(36.minutes)).to eq("In 36 minutes")
      expect(future(1.hour)).to eq("In 1 hour")
      expect(future(3.days)).to eq("In 3 days")
      expect(future(32.days)).to eq("In 4 weeks")
      expect(future(2.months)).to eq("In 2 months")
      expect(future(1.year + 1.month)).to eq("In 1 year")
    end

    it "never abbreviates units" do
      texts = [ 1.minute, 5.minutes, 3.hours, 4.days, 33.days, 3.months, 3.years ].map { |d| past(d) }
      expect(texts.join(" ")).not_to match(/\b(min|mins|hr|hrs|wk|wks|mo|mos|yr|yrs)\b/)
    end
  end

  describe "#cs_relative_time" do
    it "wraps the relative text in a time element with ISO datetime and absolute title" do
      html = helper.cs_relative_time(now - 36.minutes, now: now)
      node = Nokogiri::HTML.fragment(html).at_css("time")

      expect(node.text).to eq("36 minutes ago")
      expect(node["datetime"]).to eq("2026-10-12T11:24:00Z")
      expect(node["title"]).to eq("October 12, 2026, 11:24 (UTC+0:00)")
    end

    it "shows the title in the given zone" do
      html = helper.cs_relative_time(now - 1.hour, now: now, zone: "Eastern Time (US & Canada)")
      node = Nokogiri::HTML.fragment(html).at_css("time")

      expect(node["title"]).to eq("October 12, 2026, 07:00 (UTC-4:00)")
      expect(node["datetime"]).to eq("2026-10-12T07:00:00-04:00")
    end

    it "returns nil for nil" do
      expect(helper.cs_relative_time(nil)).to be_nil
    end
  end

  describe "#cs_absolute_time" do
    let(:time) { Time.utc(2010, 1, 31, 11, 2, 35) }

    it "uses full month names, 24-hour time without seconds and the UTC offset" do
      expect(helper.cs_absolute_time(time)).to eq("January 31, 2010, 11:02 (UTC+0:00)")
    end

    it "renders half-hour positive offsets" do
      expect(helper.cs_absolute_time(time, zone: "Tehran")).to eq("January 31, 2010, 14:32 (UTC+3:30)")
    end

    it "renders negative offsets" do
      expect(helper.cs_absolute_time(time, zone: "Eastern Time (US & Canada)")).to eq("January 31, 2010, 06:02 (UTC-5:00)")
    end

    it "renders afternoon hours on the 24-hour clock" do
      expect(helper.cs_absolute_time(Time.utc(2026, 10, 3, 21, 5))).to eq("October 3, 2026, 21:05 (UTC+0:00)")
    end

    it "renders a date only, in the given zone" do
      expect(helper.cs_absolute_time(time, date_only: true)).to eq("January 31, 2010")
      expect(helper.cs_absolute_time(Time.utc(2010, 2, 1, 2, 0), zone: "Eastern Time (US & Canada)", date_only: true)).to eq("January 31, 2010")
    end

    it "renders a Date as a date" do
      expect(helper.cs_absolute_time(Date.new(2026, 9, 5))).to eq("September 5, 2026")
    end

    it "returns nil for nil" do
      expect(helper.cs_absolute_time(nil)).to be_nil
    end
  end

  describe "#cs_absolute_time_tag" do
    it "wraps the absolute text in a time element with an ISO datetime" do
      node = Nokogiri::HTML.fragment(helper.cs_absolute_time_tag(Time.utc(2010, 1, 31, 11, 2), zone: "Tehran")).at_css("time")

      expect(node.text).to eq("January 31, 2010, 14:32 (UTC+3:30)")
      expect(node["datetime"]).to eq("2010-01-31T14:32:00+03:30")
    end

    it "uses a date-only datetime for dates" do
      node = Nokogiri::HTML.fragment(helper.cs_absolute_time_tag(Date.new(2026, 9, 5))).at_css("time")

      expect(node.text).to eq("September 5, 2026")
      expect(node["datetime"]).to eq("2026-09-05")
    end
  end

  describe "#cs_iso_time" do
    it "renders ISO 8601 with the offset" do
      expect(helper.cs_iso_time(Time.utc(2010, 1, 31, 11, 2, 35), zone: "Moscow")).to eq("2010-01-31T14:02:35+03:00")
    end
  end

  describe "#cs_date_range" do
    it "spells out months for every shape of range" do
      expect(helper.cs_date_range(Time.utc(2026, 10, 10, 9), Time.utc(2026, 10, 10, 18))).to eq("October 10, 2026")
      expect(helper.cs_date_range(Time.utc(2026, 10, 10), Time.utc(2026, 10, 17))).to eq("October 10 – 17, 2026")
      expect(helper.cs_date_range(Time.utc(2026, 10, 30), Time.utc(2026, 11, 2))).to eq("October 30 – November 2, 2026")
      expect(helper.cs_date_range(Time.utc(2026, 12, 30), Time.utc(2027, 1, 2))).to eq("December 30, 2026 – January 2, 2027")
    end

    it "handles missing ends" do
      expect(helper.cs_date_range(nil, nil)).to eq("Dates not set")
      expect(helper.cs_date_range(nil, Time.utc(2026, 10, 17))).to eq("Ends October 17, 2026")
      expect(helper.cs_date_range(Time.utc(2026, 10, 10), nil)).to eq("October 10, 2026")
    end

    it "reads dates in the given zone" do
      expect(helper.cs_date_range(Time.utc(2026, 10, 10, 2), Time.utc(2026, 10, 12, 2), zone: "Pacific Time (US & Canada)"))
        .to eq("October 9 – 11, 2026")
    end
  end
end
