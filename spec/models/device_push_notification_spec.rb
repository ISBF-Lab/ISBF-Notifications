# frozen_string_literal: true

RSpec.describe Notification do
  fab!(:recipient, :user)
  fab!(:topic, :topic_with_op)
  fab!(:subscription) { Fabricate(:push_subscription, user: recipient) }

  before do
    SiteSetting.isbf_notifications_enabled = true
    SiteSetting.isbf_device_push_liked = true
    SiteSetting.push_notification_time_window_mins = 0
  end

  describe "#save!" do
    it "enqueues a newly created supplemental notification once" do
      expect do
        Fabricate(
          :notification,
          user: recipient,
          topic:,
          post_number: 1,
          notification_type: Notification.types[:liked],
        )
      end.to change { Jobs::DeliverPushNotification.jobs.size }.by(1)
    end

    it "keeps native push events on their existing path" do
      expect do
        Fabricate(
          :notification,
          user: recipient,
          topic:,
          post_number: 1,
          notification_type: Notification.types[:replied],
        )
      end.not_to change { Jobs::DeliverPushNotification.jobs.size }
    end

    it "pushes a later consolidated update without sending when the record is marked read" do
      notification =
        Fabricate(
          :notification,
          user: recipient,
          topic:,
          post_number: 1,
          notification_type: Notification.types[:liked_consolidated],
          data: { count: 2 }.to_json,
        )

      expect do notification.update!(data: { count: 3 }.to_json) end.to change {
        Jobs::DeliverPushNotification.jobs.size
      }.by(1)
      expect do notification.update!(read: true) end.not_to change {
        Jobs::DeliverPushNotification.jobs.size
      }
    end

    it "keeps the in-site calendar cancellation and native email suppression" do
      SiteSetting.isbf_device_push_calendar_changed = true
      item = Fabricate(:isbf_notifications_calendar_item, topic:, cancelled: true)
      entry = Fabricate(:isbf_notifications_calendar_entry, source_item: item, user: recipient)

      expect do
        Jobs::IsbfCalendarNotifyChange.new.execute(item_id: item.id, revision: item.revision)
      end.to change {
        recipient.notifications.where(notification_type: Notification.types[:custom]).count
      }.by(1).and change { Jobs::DeliverPushNotification.jobs.size }.by(1).and not_change {
                    Jobs::UserEmail.jobs.size
                  }

      notification = recipient.notifications.order(:id).last
      expect(notification.data_hash).to include(
        "message" => "isbf_calendar.changed",
        "entry_id" => entry.id,
      )
      expect(notification.reload.read).to eq(false)
    end
  end
end
