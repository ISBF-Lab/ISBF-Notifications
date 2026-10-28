# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Calendar reminder device delivery" do
  fab!(:recipient) { Fabricate(:user, approved: true) }
  fab!(:category)
  fab!(:official_group, :group)

  let(:entry) do
    IsbfCalendar::Entry.create!(
      user: recipient,
      title: "<b>Study</b> &amp; prepare",
      note: "Private preparation notes",
      location: "Private meeting place",
      starts_at: 2.hours.from_now,
      ends_at: 3.hours.from_now,
      all_day: false,
      reminder_mode: "before_15m",
    )
  end

  let(:hub_key) do
    Fabricate(
      :user_api_key,
      user: recipient,
      user_api_key_client_id: Fabricate(:user_api_key_client).id,
      scopes: [Fabricate.build(:user_api_key_scope, name: "notifications")],
      push_url: "https://hub.example.com/push",
    )
  end

  before do
    freeze_time Time.utc(2026, 10, 28)
    SiteSetting.isbf_notifications_enabled = true
    SiteSetting.isbf_device_push_scheduled_event = true
    SiteSetting.isbf_device_push_calendar_changed = false
    SiteSetting.isbf_calendar_reminders_enabled = true
    SiteSetting.isbf_calendar_reminder_delivery_mode = "in_app"
    SiteSetting.academy_official_category = category.id
    SiteSetting.academy_official_group = official_group.id
    SiteSetting.academy_roles_enabled = true
    SiteSetting.allow_user_locale = true
    SiteSetting.push_notification_time_window_mins = 0
    SiteSetting.allowed_user_api_push_urls = "https://hub.example.com/push"
    recipient.update!(locale: "zh_CN", last_seen_at: 1.day.ago)
    %w[https://web.push.apple.com/test https://fcm.googleapis.com/test].each do |endpoint|
      Fabricate(
        :push_subscription,
        user: recipient,
        data: { endpoint:, keys: { p256dh: "key", auth: "auth" } }.to_json,
      )
    end
    WebPush.stubs(:payload_send)
    Jobs::DeliverPushNotification.clear
  end

  def queue_reminder(record)
    freeze_time record.reminder_at
    IsbfCalendar::Reminders.process!(record, now: Time.current)
    Jobs::DeliverPushNotification.jobs.last&.fetch("args")&.first&.deep_symbolize_keys
  end

  def deliver(arguments)
    DiscourseEvent
      .track_events(:push_notification_sent) do
        Jobs::DeliverPushNotification.new.execute(arguments)
      end
      .map { |event| event[:params][1] }
  end

  it "delivers one sanitized reminder to Apple and Google without sending email" do
    hub_key
    request =
      stub_request(:post, "https://hub.example.com/push")
        .with do |sent|
          notification = JSON.parse(sent.body).fetch("notifications").first
          notification["translated_title"] == "Study & prepare" &&
            notification["excerpt"] == "你设置的日程提醒已到时间。" &&
            notification["url"] == "#{Discourse.base_url}/isbf/calendar?entry_id=#{entry.id}"
        end
        .to_return(status: 200)
    email_count = Jobs::UserEmail.jobs.size
    arguments = queue_reminder(entry)

    expect(Jobs::DeliverPushNotification.jobs.size).to eq(1)
    notification = recipient.notifications.last
    expect(notification).to have_attributes(
      read: false,
      notification_type: Notification.types[:custom],
    )
    expect(notification.data_hash).to include(
      "message" => "isbf_calendar.reminder",
      "entry_id" => entry.id,
    )
    expect(Jobs::UserEmail.jobs.size).to eq(email_count)
    expect(deliver(arguments)).to contain_exactly(
      include(
        title: "Study & prepare",
        body: "你设置的日程提醒已到时间。",
        url: "/isbf/calendar?entry_id=#{entry.id}",
      ),
      include(
        title: "Study & prepare",
        body: "你设置的日程提醒已到时间。",
        url: "/isbf/calendar?entry_id=#{entry.id}",
      ),
    )
    expect(request).to have_been_requested.once
    expect(notification.reload.read).to eq(false)
  end

  it "keeps retries and note or notification updates from creating another delivery" do
    queue_reminder(entry)
    notification = recipient.notifications.last
    entry.update!(note: "Updated private note", location: "Updated private place")
    notification.update!(data: notification.data_hash.merge(topic_title: "Updated title").to_json)

    expect { IsbfCalendar::Reminders.process!(entry, now: Time.current) }.not_to change {
      Jobs::DeliverPushNotification.jobs.size
    }
    expect(Jobs::DeliverPushNotification.jobs.size).to eq(1)
    expect(
      recipient.notifications.where(notification_type: Notification.types[:custom]).count,
    ).to eq(1)
  end

  it "uses separate tags for different entries and opens their own calendar record" do
    first_arguments = queue_reminder(entry)
    freeze_time 1.day.ago
    other =
      IsbfCalendar::Entry.create!(
        user: recipient,
        title: "Another reminder",
        starts_at: entry.starts_at,
        ends_at: entry.ends_at,
        all_day: false,
        reminder_mode: "before_15m",
      )
    second_arguments = queue_reminder(other)

    first = deliver(first_arguments).first
    second = deliver(second_arguments).first
    expect(first[:tag]).not_to eq(second[:tag])
    expect([first[:url], second[:url]]).to eq(
      ["/isbf/calendar?entry_id=#{entry.id}", "/isbf/calendar?entry_id=#{other.id}"],
    )
  end

  it "delivers all-day reminders in their configured time zone" do
    entry.update!(
      all_day: true,
      starts_at: Time.utc(2026, 10, 29),
      ends_at: Time.utc(2026, 10, 31),
      reminder_mode: "same_day_9am",
      reminder_timezone: "America/New_York",
    )

    arguments = queue_reminder(entry)

    expect(Time.current.in_time_zone("America/New_York").hour).to eq(9)
    expect(deliver(arguments).size).to eq(2)
  end

  %w[event deadline].each do |kind|
    it "delivers an official #{kind} using the saved reminder time" do
      item =
        Fabricate(:isbf_notifications_calendar_item, topic: Fabricate(:topic_with_op, category:))
      item.update!(schedule_kind: kind, ends_at: kind == "deadline" ? item.starts_at : item.ends_at)
      record =
        Fabricate(
          :isbf_notifications_calendar_entry,
          user: recipient,
          source_item: item,
          reminder_mode: "before_5m",
        )

      arguments = queue_reminder(record)

      expect(deliver(arguments)).to contain_exactly(
        include(title: record.title, url: "/isbf/calendar?entry_id=#{record.id}"),
        include(title: record.title, url: "/isbf/calendar?entry_id=#{record.id}"),
      )
      expect(Jobs::DeliverPushNotification.jobs.size).to eq(1)
    end
  end

  it "leaves verified subscription-calendar delivery without an in-site or device duplicate" do
    SiteSetting.isbf_calendar_reminder_delivery_mode = "subscription_preferred"
    client =
      UserApiKeyClient.find_or_create_by!(client_id: "calendar-subscriptions") do |record|
        record.application_name = "Calendar subscriptions"
      end
    key =
      Fabricate(
        :user_api_key,
        user: recipient,
        client:,
        scopes: [Fabricate.build(:user_api_key_scope, name: IsbfCalendar::SubscriptionFeed::SCOPE)],
      )
    IsbfCalendar::Reminders.acknowledge_exports(
      user: recipient,
      key:,
      snapshots: [{ id: entry.id, generation: entry.reminder_generation, at: entry.reminder_at }],
      policy_version: IsbfCalendar::Reminders.policy_version,
    )

    arguments = queue_reminder(entry)

    expect(arguments).to be_nil
    expect(entry.reload.reminder_delivery).to eq("calendar")
    expect(
      recipient.notifications.where(notification_type: Notification.types[:custom]),
    ).to be_empty
  end

  it "falls back to the in-site device path when no calendar subscription has fetched this reminder" do
    SiteSetting.isbf_calendar_reminder_delivery_mode = "subscription_preferred"

    arguments = queue_reminder(entry)

    expect(entry.reload.reminder_delivery).to eq("in_app")
    expect(deliver(arguments).size).to eq(2)
  end

  %i[
    isbf_notifications_enabled
    isbf_device_push_scheduled_event
    isbf_calendar_reminders_enabled
  ].each do |setting|
    it "suppresses an already queued reminder after #{setting} is disabled" do
      arguments = queue_reminder(entry)
      SiteSetting.public_send("#{setting}=", false)

      expect(deliver(arguments)).to be_empty
    end
  end

  it "preserves the in-site notice when the device-reminder switch is off" do
    SiteSetting.isbf_device_push_scheduled_event = false

    arguments = queue_reminder(entry)

    expect(arguments).to be_nil
    expect(recipient.notifications.last.data_hash[:entry_id]).to eq(entry.id)
  end

  it "honors native do-not-disturb before enqueue and again before delivery" do
    entry
    timing = Fabricate(:do_not_disturb_timing, user: recipient, ends_at: 1.day.from_now)
    expect(queue_reminder(entry)).to be_nil
    timing.destroy!
    entry.update!(starts_at: 1.hour.from_now, ends_at: 2.hours.from_now)
    arguments = queue_reminder(entry)
    Fabricate(:do_not_disturb_timing, user: recipient, ends_at: 1.day.from_now)

    expect(deliver(arguments)).to be_empty
  end

  it "honors the native recent-activity delay" do
    entry
    SiteSetting.push_notification_time_window_mins = 10
    recipient.update!(last_seen_at: entry.reminder_at)

    arguments = queue_reminder(entry)

    expect(Jobs::DeliverPushNotification.jobs.last["at"]).to be > Time.current.to_f
    expect(deliver(arguments)).to be_empty
  end

  it "withholds a queued reminder once the notice is read or removed" do
    hub_key
    request = stub_request(:post, "https://hub.example.com/push").to_return(status: 200)
    arguments = queue_reminder(entry)
    notification = recipient.notifications.last
    notification.update!(read: true)
    expect(deliver(arguments)).to be_empty
    notification.update!(read: false)
    notification.destroy!
    expect(deliver(arguments)).to be_empty
    expect(request).not_to have_been_requested
  end

  it "withholds a queued reminder when disabled or removed from the owner's calendar" do
    arguments = queue_reminder(entry)
    entry.update!(reminder_mode: "none")
    expect(deliver(arguments)).to be_empty
    entry.destroy!
    expect(deliver(arguments)).to be_empty
  end

  it "rejects a previous generation after rescheduling and keeps the new reminder separate" do
    old_arguments = queue_reminder(entry)
    old_notification = recipient.notifications.last
    entry.update!(starts_at: 2.hours.from_now, ends_at: 3.hours.from_now)
    expect(deliver(old_arguments)).to be_empty
    new_arguments = queue_reminder(entry)

    expect(deliver(old_arguments)).to be_empty
    expect(deliver(new_arguments).size).to eq(2)
    expect(
      IsbfNotifications::DevicePushPolicy.new(recipient).presentation(
        IsbfNotifications::DevicePushPolicy.new(recipient).payload_for(old_notification),
      ),
    ).to include(enabled: false)
  end

  it "rejects a mismatched recipient without exposing another user's event" do
    arguments = queue_reminder(entry)
    arguments[:user_id] = Fabricate(:user, approved: true).id

    expect(deliver(arguments)).to be_empty
  end

  [11.minutes, 16.minutes].each do |delay|
    it "drops a queued reminder delayed by #{delay.to_i} seconds beyond its valid window" do
      arguments = queue_reminder(entry)
      freeze_time delay.from_now

      expect(deliver(arguments)).to be_empty
    end
  end

  [
    { active: false },
    { approved: false },
    { staged: true },
    { suspended_till: Time.utc(2027, 1, 1) },
  ].each do |state|
    it "withholds queued reminders after the recipient becomes #{state.keys.first}" do
      arguments = queue_reminder(entry)
      recipient.update_columns(**state)

      expect(deliver(arguments)).to be_empty
    end
  end

  %i[cancelled hidden inaccessible deleted].each do |change|
    it "withholds an official reminder when its source becomes #{change}" do
      item =
        Fabricate(:isbf_notifications_calendar_item, topic: Fabricate(:topic_with_op, category:))
      record =
        Fabricate(
          :isbf_notifications_calendar_entry,
          user: recipient,
          source_item: item,
          reminder_mode: "before_15m",
        )
      arguments = queue_reminder(record)
      case change
      when :cancelled
        item.update!(cancelled: true)
      when :hidden
        item.topic.first_post.update!(hidden: true)
      when :inaccessible
        category.set_permissions(staff: :full)
        category.save!
      when :deleted
        item.topic.update!(deleted_at: Time.current)
      end

      expect(deliver(arguments)).to be_empty
    end
  end
end
