# frozen_string_literal: true

RSpec.describe PushNotificationPusher do
  fab!(:recipient, :user)
  fab!(:actor, :user)
  fab!(:topic, :topic_with_op)

  before do
    SiteSetting.isbf_notifications_enabled = true
    SiteSetting.allow_user_locale = true
    SiteSetting.push_notification_time_window_mins = 0
    recipient.update!(locale: "zh_CN", last_seen_at: 1.minute.ago)
  end

  describe ".push" do
    let(:payload) do
      {
        notification_type: Notification.types[:replied],
        topic_id: topic.id,
        topic_title: topic.title,
        post_url: topic.first_post.url,
        excerpt: topic.first_post.raw,
        username: actor.username,
        tag: "original-tag",
        actions: [{ action: "reply", title: "Reply" }],
        action_data: {
          topic_id: topic.id,
        },
      }
    end

    it "uses identical summaries for Apple and Google subscriptions and preserves navigation data" do
      Fabricate(
        :push_subscription,
        user: recipient,
        data: {
          endpoint: "https://web.push.apple.com/test",
          keys: {
            p256dh: "key",
            auth: "auth",
          },
        }.to_json,
      )
      Fabricate(
        :push_subscription,
        user: recipient,
        data: {
          endpoint: "https://fcm.googleapis.com/test",
          keys: {
            p256dh: "key",
            auth: "auth",
          },
        }.to_json,
      )
      WebPush.stubs(:payload_send)

      events =
        DiscourseEvent.track_events(:push_notification_sent) do
          described_class.push(recipient, payload)
        end
      messages = events.map { |event| event[:params][1] }

      expect(messages.size).to eq(2)
      expect(messages.uniq).to contain_exactly(
        include(
          title: topic.title,
          body: "你收到一条新回复。",
          url: topic.first_post.url,
          tag: payload[:tag],
          actions: payload[:actions],
          action_data: payload[:action_data],
        ),
      )
      expect(messages.flat_map(&:values)).not_to include(topic.first_post.raw)
      expect(payload[:excerpt]).to eq(topic.first_post.raw)
    end

    it "skips Web Push when the event switch is off" do
      SiteSetting.isbf_device_push_replied = false
      Fabricate(:push_subscription, user: recipient)
      WebPush.stubs(:payload_send)

      events =
        DiscourseEvent.track_events(:push_notification_sent) do
          described_class.push(recipient, payload)
        end

      expect(events).to be_empty
    end

    it "uses the triggering post instead of a stale parent link for device push" do
      parent = Fabricate(:post, topic:, user: recipient)
      reply = Fabricate(:post, topic:, user: actor, reply_to_post_number: parent.post_number)
      stale_payload =
        payload.merge(post_id: reply.id, post_number: parent.post_number, post_url: parent.url)

      message = described_class.push(recipient, stale_payload)

      expect(message).to include(url: reply.url, title: topic.title, body: "你收到一条新回复。")
      expect(stale_payload).to include(post_number: parent.post_number, post_url: parent.url)
    end

    it "uses normal Web Push output while the plugin is disabled" do
      SiteSetting.isbf_notifications_enabled = false

      expect(described_class.push(recipient, payload)).to include(body: topic.first_post.raw)
    end
  end
end
