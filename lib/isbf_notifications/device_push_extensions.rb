# frozen_string_literal: true

module IsbfNotifications
  module DevicePushPusher
    def push(user, payload)
      return super unless SiteSetting.isbf_notifications_enabled

      policy = DevicePushPolicy.new(user)
      payload = payload.with_indifferent_access
      return unless policy.enabled?(payload, web_push: true)

      super(user, policy.web_payload(payload))
    end
  end

  module CalendarReminderDelivery
    def execute(args)
      payload = (args[:payload] || {}).with_indifferent_access
      if DevicePushPolicy.calendar_reminder_payload?(payload)
        user = User.find_by(id: args[:user_id])
        return unless SiteSetting.isbf_notifications_enabled && user && !user.do_not_disturb?
        return unless DevicePushPolicy.new(user).enabled?(payload, web_push: true)
      end
      super
    end
  end

  module DevicePushNotificationsController
    def serialize_data(objects, serializer, options = nil)
      if SiteSetting.isbf_notifications_enabled && serializer == NotificationSerializer &&
           params[:device_push] == "true"
        policy = DevicePushPolicy.new(current_user, notifications: Array(objects))
        options = (options || {}).merge(isbf_device_push_policy: policy)
      end
      super(objects, serializer, options)
    end
  end
end
