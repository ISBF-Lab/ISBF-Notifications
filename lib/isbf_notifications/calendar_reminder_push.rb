# frozen_string_literal: true

module IsbfNotifications
  module CalendarReminderPush
    def self.snapshot(notification, entry)
      unless defined?(::IsbfCalendar::Reminders) && entry &&
               notification.user_id == entry.user_id && entry.reminder_at &&
               entry.reminder_processed_at && entry.reminder_delivery == "in_app" &&
               notification.created_at && entry.reminder_processed_at <= notification.created_at &&
               notification.created_at <=
                 entry.reminder_processed_at + ::IsbfCalendar::Reminders::CATCHUP
        return
      end

      {
        notification_id: notification.id,
        generation: entry.reminder_generation,
        reminder_at: entry.reminder_at.iso8601(6),
      }
    end

    def self.enabled?(user, payload, entry, notification: nil, now: Time.current)
      return false unless defined?(::IsbfCalendar::Reminders) && entry
      reminders = ::IsbfCalendar::Reminders
      raw = payload[:isbf_calendar_reminder]
      return false unless raw.is_a?(Hash)
      snapshot = raw.with_indifferent_access
      unless reminders.enabled? && SiteSetting.isbf_device_push_scheduled_event &&
               reminders.eligible_user?(user) && reminders.available_source?(entry, user.guardian)
        return false
      end
      unless entry.user_id == user.id && entry.reminder_mode != "none" &&
               entry.reminder_delivery == "in_app" && entry.reminder_processed_at &&
               entry.reminder_at && entry.reminder_generation == snapshot[:generation] &&
               entry.reminder_at.iso8601(6) == snapshot[:reminder_at] && entry.reminder_at <= now &&
               entry.reminder_at >= now - reminders::CATCHUP && entry.reminder_configured_at &&
               entry.reminder_at > entry.reminder_configured_at
        return false
      end

      changed_at = reminders.policy_changed_at
      return false if changed_at && entry.reminder_at < changed_at

      notification ||= Notification.find_by(id: snapshot[:notification_id], user_id: user.id)
      unless notification && notification.user_id == user.id && !notification.read &&
               DevicePushPolicy.calendar_reminder?(notification) &&
               notification.data_hash[:entry_id].to_i == entry.id &&
               self.snapshot(notification, entry) == snapshot.symbolize_keys
        return false
      end
      return entry.starts_at > now unless entry.all_day?
      return false unless reminders.valid_timezone?(entry.reminder_timezone)

      now.in_time_zone(entry.reminder_timezone).to_date ==
        entry.reminder_at.in_time_zone(entry.reminder_timezone).to_date
    end
  end
end
