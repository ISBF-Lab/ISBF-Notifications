# frozen_string_literal: true

Fabricator(:isbf_notifications_calendar_item, class_name: "IsbfCalendar::OfficialItem") do
  topic { Fabricate(:topic_with_op) }
  title "Campus activity"
  schedule_kind "event"
  starts_at { 2.hours.from_now }
  ends_at { 3.hours.from_now }
  all_day false
end

Fabricator(:isbf_notifications_calendar_entry, class_name: "IsbfCalendar::Entry") do
  user
  source_item { Fabricate(:isbf_notifications_calendar_item) }
  title { |attributes| attributes[:source_item].title }
  schedule_kind { |attributes| attributes[:source_item].schedule_kind }
  starts_at { |attributes| attributes[:source_item].starts_at }
  ends_at { |attributes| attributes[:source_item].ends_at }
  all_day false
end
