# frozen_string_literal: true

RSpec.describe PostAlerter do
  fab!(:recipient, :user)
  fab!(:actor, :user)
  fab!(:topic, :topic_with_op)

  describe "#create_notification" do
    subject(:notification) do
      described_class.new.create_notification(recipient, Notification.types[:replied], reply)
    end

    let(:reply) { Fabricate(:post, topic:, user: actor) }
    let(:messages) do
      MessageBus.track_publish("/notification-alert/#{recipient.id}") { notification }
    end

    before do
      SiteSetting.isbf_notifications_enabled = true
      SiteSetting.push_notification_time_window_mins = 0
      NotificationEmailer.enable
      recipient.update!(last_seen_at: 1.minute.ago)
    end

    it "keeps in-site records, email jobs and live alerts when device push is disabled" do
      SiteSetting.isbf_device_push_replied = false
      recipient.user_option.update!(email_level: UserOption.email_level_types[:always])
      reply

      expect { messages }.to change { recipient.notifications.count }.by(1).and change {
              Jobs::UserEmail.jobs.size
            }.by(1)

      expect(notification.reload).to have_attributes(
        notification_type: Notification.types[:replied],
        read: false,
      )
      expect(messages.map(&:user_ids)).to eq([[recipient.id]])
      expect(messages.first.data[:excerpt]).to eq(
        reply.excerpt(
          400,
          text_entities: true,
          strip_links: true,
          remap_emoji: true,
          plain_hashtags: true,
        ),
      )
      expect(PushNotificationPusher.push(recipient, messages.first.data)).to be_nil
    end
  end
end
