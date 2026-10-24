# frozen_string_literal: true

module IsbfNotifications
  class SendSupplementalPush
    include Service::Base

    params do
      attribute :notification_id, :integer
      validates :notification_id, presence: true
    end

    model :notification
    policy :supplemental_event
    policy :push_enabled
    step :enqueue_push

    private

    def fetch_notification(params:)
      Notification.includes(:user, :topic).find_by(id: params.notification_id)
    end

    def supplemental_event(notification:)
      DevicePushPolicy.supplemental?(notification)
    end

    def push_enabled(notification:)
      policy = DevicePushPolicy.new(notification.user)
      guardian = notification.user.guardian
      visible_topic = !notification.topic || guardian.can_see?(notification.topic)
      visible_post =
        !notification.topic || !notification.post_number ||
          guardian.can_see?(notification.topic.posts.find_by(post_number: notification.post_number))
      SiteSetting.isbf_notifications_enabled && !notification.read &&
        !notification.user.suspended? && visible_topic && visible_post &&
        policy.enabled?(policy.payload_for(notification))
    end

    def enqueue_push(notification:)
      policy = DevicePushPolicy.new(notification.user)
      PostAlerter.push_notification(notification.user, policy.payload_for(notification))
    end
  end
end
