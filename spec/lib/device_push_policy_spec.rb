# frozen_string_literal: true

RSpec.describe IsbfNotifications::DevicePushPolicy do
  fab!(:recipient, :user)
  fab!(:other_user, :user)
  fab!(:official_group, :group)
  fab!(:topic, :topic_with_op)

  before do
    SiteSetting.isbf_notifications_enabled = true
    SiteSetting.allow_user_locale = true
    SiteSetting.academy_official_category = topic.category_id
    SiteSetting.academy_official_group = official_group.id
    SiteSetting.academy_roles_enabled = true
    recipient.update!(locale: "zh_CN")
  end

  describe "#enabled?" do
    let(:policy) { described_class.new(recipient) }

    {
      liked: %i[liked liked_consolidated],
      replied: %i[replied reaction],
      mentioned: %i[mentioned group_mentioned],
      following: %i[posted watching_first_post watching_category_or_tag],
      private_message: %i[private_message],
      chat_message: %i[chat_message chat_watched_thread],
      chat_mention: %i[chat_mention],
      topic_reminder: %i[topic_reminder],
    }.each do |setting, types|
      it "shares the #{setting} switch across its events and device channels" do
        SiteSetting.public_send("isbf_device_push_#{setting}=", false)
        types.each do |type|
          payload = { notification_type: Notification.types.fetch(type) }
          expect(policy.enabled?(payload)).to eq(false)
          expect(policy.enabled?(payload, web_push: true)).to eq(false)
        end

        SiteSetting.public_send("isbf_device_push_#{setting}=", true)
        types.each do |type|
          payload = { notification_type: Notification.types.fetch(type) }
          expect(policy.enabled?(payload)).to eq(true)
          expect(policy.enabled?(payload, web_push: true)).to eq(true)
        end
      end
    end

    it "starts with the reviewed iPhone event scope" do
      expect(
        %i[
          liked
          replied
          mentioned
          following
          private_message
          chat_message
          chat_mention
          topic_reminder
          scheduled_event
          calendar_changed
        ].to_h { |setting| [setting, SiteSetting.public_send("isbf_device_push_#{setting}")] },
      ).to eq(
        liked: false,
        replied: true,
        mentioned: true,
        following: true,
        private_message: true,
        chat_message: true,
        chat_mention: true,
        topic_reminder: false,
        scheduled_event: true,
        calendar_changed: false,
      )
    end

    it "keeps other native iPhone events eligible and excludes site-only notices from direct push" do
      expect(
        %i[quoted linked].map do |type|
          policy.enabled?({ notification_type: Notification.types.fetch(type) })
        end,
      ).to eq([true, true])
      expect(
        %i[edited granted_badge bookmark_reminder event_invitation].map do |type|
          policy.enabled?({ notification_type: Notification.types.fetch(type) })
        end,
      ).to eq([false, false, false, false])
    end

    it "requires an event in this recipient's personal schedule" do
      item = Fabricate(:isbf_notifications_calendar_item, topic:)
      payload = { notification_type: Notification.types[:event_reminder], topic_id: topic.id }
      Fabricate(:isbf_notifications_calendar_entry, user: other_user, source_item: item)

      expect(policy.enabled?(payload)).to eq(false)
      own_entry = Fabricate(:isbf_notifications_calendar_entry, user: recipient, source_item: item)
      own_policy = described_class.new(recipient)
      expect(own_policy.enabled?(payload)).to eq(true)
      expect(own_policy.enabled?(payload, web_push: true)).to eq(true)

      SiteSetting.isbf_device_push_scheduled_event = false
      expect(own_policy.enabled?(payload)).to eq(false)
      expect(own_entry.reload.source_item).to eq(item)
    end

    it "excludes deadline entries and cancelled activities from activity reminders" do
      item = Fabricate(:isbf_notifications_calendar_item, topic:, cancelled: true)
      Fabricate(:isbf_notifications_calendar_entry, user: recipient, source_item: item)
      payload = { notification_type: Notification.types[:event_reminder], topic_id: topic.id }
      expect(policy.enabled?(payload)).to eq(false)

      deadline_at = 2.hours.from_now
      deadline_item =
        Fabricate(
          :isbf_notifications_calendar_item,
          starts_at: deadline_at,
          ends_at: deadline_at,
          schedule_kind: "deadline",
        )
      Fabricate(:isbf_notifications_calendar_entry, user: recipient, source_item: deadline_item)
      expect(
        described_class.new(recipient).enabled?(payload.merge(topic_id: deadline_item.topic_id)),
      ).to eq(false)
    end

    it "scopes calendar updates to the recipient and the calendar switch" do
      own_entry = Fabricate(:isbf_notifications_calendar_entry, user: recipient)
      foreign_entry = Fabricate(:isbf_notifications_calendar_entry, user: other_user)
      payload = {
        notification_type: Notification.types[:custom],
        notification_data: {
          message: "isbf_calendar.changed",
          entry_id: own_entry.id,
        },
      }

      expect(policy.enabled?(payload)).to eq(false)
      SiteSetting.isbf_device_push_calendar_changed = true
      expect(policy.enabled?(payload)).to eq(true)
      expect(policy.enabled?(payload, web_push: true)).to eq(true)
      expect(
        policy.enabled?(payload.deep_merge(notification_data: { entry_id: foreign_entry.id })),
      ).to eq(false)
      expect(policy.enabled?(payload.deep_merge(notification_data: { entry_id: 0 }))).to eq(false)
    end

    it "excludes activity reminders when the saved source post is hidden" do
      item = Fabricate(:isbf_notifications_calendar_item, topic:)
      Fabricate(:isbf_notifications_calendar_entry, user: recipient, source_item: item)
      topic.first_post.update!(hidden: true)

      expect(
        policy.enabled?(
          { notification_type: Notification.types[:event_reminder], topic_id: topic.id },
        ),
      ).to eq(false)
    end
  end

  describe "#presentation" do
    let(:policy) { described_class.new(recipient) }

    it "uses the post title and an action summary without the post body" do
      payload = {
        notification_type: Notification.types[:replied],
        topic_title: topic.title,
        excerpt: topic.first_post.raw,
      }
      expect(policy.presentation(payload)).to eq(
        version: 1,
        enabled: true,
        title: topic.title,
        body: "你收到一条新回复。",
      )
      expect(policy.presentation(payload).values).not_to include(topic.first_post.raw)
    end

    it "distinguishes merged event wording while keeping the shared switch" do
      bodies = {
        liked: "你的帖子收到点赞。",
        liked_consolidated: "你的帖子收到点赞。",
        reaction: "你的帖子收到表情回应。",
        replied: "你收到一条新回复。",
        mentioned: "有人在帖子中 @ 了你。",
        group_mentioned: "有人在帖子中 @ 了你所在的用户组。",
        posted: "你关注的内容有新消息。",
        watching_first_post: "你关注的内容有新消息。",
        watching_category_or_tag: "你关注的内容有新消息。",
        private_message: "你收到一条新私信。",
        chat_message: "你收到一条新的聊天消息。",
        chat_watched_thread: "你收到一条新的聊天消息。",
        chat_mention: "有人在聊天中 @ 了你。",
        topic_reminder: "你设置的主题提醒已到时间。",
      }
      actual_bodies =
        bodies.keys.to_h do |type|
          [
            type,
            policy.presentation(
              notification_type: Notification.types.fetch(type),
              topic_title: topic.title,
            )[
              :body
            ],
          ]
        end
      expect(actual_bodies).to eq(bodies)
    end

    it "uses the chat channel title instead of a message excerpt" do
      channel = Fabricate(:category_channel, name: "选课交流")
      payload = {
        notification_type: Notification.types[:chat_message],
        channel_id: channel.id,
        topic_title: "Message excerpt must not become a title",
      }
      expect(policy.presentation(payload)).to include(
        title: channel.title(recipient),
        body: "你收到一条新的聊天消息。",
      )
    end

    it "uses distinct activity phases for an activity already in the personal schedule" do
      freeze_time
      item = Fabricate(:isbf_notifications_calendar_item, topic:)
      Fabricate(:isbf_notifications_calendar_entry, source_item: item, user: recipient)
      payload = {
        notification_type: Notification.types[:event_reminder],
        topic_id: topic.id,
        topic_title: topic.title,
      }
      expect(policy.presentation(payload)[:body]).to eq("你加入日程的活动即将开始。")
      item.update!(starts_at: 10.minutes.ago, ends_at: 1.hour.from_now)
      expect(described_class.new(recipient).presentation(payload)[:body]).to eq("你加入日程的活动正在进行。")
      item.update!(starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      expect(described_class.new(recipient).presentation(payload)[:body]).to eq("你加入日程的活动已结束。")
      explicit_reminder =
        payload.merge(
          notification_data: {
            message: "discourse_post_event.notifications.before_event_reminder",
          },
        )
      expect(described_class.new(recipient).presentation(explicit_reminder)[:body]).to eq(
        "你加入日程的活动即将开始。",
      )
    end

    it "uses the source post title and distinguishes calendar changes from cancellations" do
      SiteSetting.isbf_device_push_calendar_changed = true
      item = Fabricate(:isbf_notifications_calendar_item, topic:)
      entry = Fabricate(:isbf_notifications_calendar_entry, source_item: item, user: recipient)
      payload = {
        notification_type: Notification.types[:custom],
        notification_data: {
          message: "isbf_calendar.changed",
          entry_id: entry.id,
        },
      }
      expect(policy.presentation(payload)).to eq(
        version: 1,
        enabled: true,
        title: topic.title,
        body: "你添加的日程有更新，请查看。",
      )
      item.update!(cancelled: true)
      expect(described_class.new(recipient).presentation(payload)).to eq(
        version: 1,
        enabled: true,
        title: topic.title,
        body: "你添加的日程已取消。",
      )
    end

    it "uses the saved entry title when the source post is no longer visible" do
      SiteSetting.isbf_device_push_calendar_changed = true
      item = Fabricate(:isbf_notifications_calendar_item, topic:)
      entry =
        Fabricate(
          :isbf_notifications_calendar_entry,
          user: recipient,
          source_item: item,
          title: "Saved personal schedule",
        )
      topic.first_post.update!(hidden: true)
      payload = {
        notification_type: Notification.types[:custom],
        notification_data: {
          message: "isbf_calendar.changed",
          entry_id: entry.id,
        },
      }

      expect(policy.presentation(payload)).to include(enabled: false, title: entry.title)
    end

    it "loads chat and calendar presentation data in a fixed number of queries" do
      SiteSetting.isbf_device_push_calendar_changed = true
      notices =
        4.times.flat_map do
          channel = Fabricate(:category_channel)
          item = Fabricate(:isbf_notifications_calendar_item)
          entry = Fabricate(:isbf_notifications_calendar_entry, source_item: item, user: recipient)
          [
            Fabricate(
              :notification,
              user: recipient,
              topic: nil,
              notification_type: Notification.types[:chat_message],
              data: { chat_channel_id: channel.id }.to_json,
            ),
            Fabricate(
              :notification,
              user: recipient,
              topic: nil,
              notification_type: Notification.types[:custom],
              data: { message: "isbf_calendar.changed", entry_id: entry.id }.to_json,
            ),
            Fabricate(
              :notification,
              user: recipient,
              topic: item.topic,
              notification_type: Notification.types[:event_reminder],
            ),
          ]
        end
      described_class.new(recipient, notifications: notices).presentation(
        notification_type: Notification.types[:replied],
        topic_title: topic.title,
      )

      single_queries =
        track_sql_queries do
          single = described_class.new(recipient, notifications: notices.first(3))
          notices
            .first(3)
            .each { |notification| single.presentation(single.payload_for(notification)) }
        end
      multiple_queries =
        track_sql_queries do
          multiple = described_class.new(recipient, notifications: notices)
          notices.each { |notification| multiple.presentation(multiple.payload_for(notification)) }
        end

      expect(multiple_queries.size).to eq(single_queries.size)
    end
  end
end
