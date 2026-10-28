# frozen_string_literal: true

module IsbfNotifications
  class DevicePushPolicy
    SCHEMA_VERSION = 1
    SETTINGS = {
      liked: :liked,
      liked_consolidated: :liked,
      reaction: :replied,
      replied: :replied,
      mentioned: :mentioned,
      group_mentioned: :mentioned,
      posted: :following,
      watching_first_post: :following,
      watching_category_or_tag: :following,
      private_message: :private_message,
      chat_message: :chat_message,
      chat_watched_thread: :chat_message,
      chat_mention: :chat_mention,
      topic_reminder: :topic_reminder,
      event_reminder: :scheduled_event,
    }.freeze
    SUPPLEMENTAL_TYPES = %i[liked liked_consolidated reaction topic_reminder].freeze
    POST_EVENT_TYPES = %i[
      replied
      posted
      private_message
      mentioned
      group_mentioned
      quoted
      linked
      watching_first_post
      watching_category_or_tag
    ].freeze
    BODY_KEYS = {
      liked: :liked,
      liked_consolidated: :liked,
      reaction: :reaction,
      replied: :replied,
      mentioned: :mentioned,
      group_mentioned: :group_mentioned,
      posted: :following,
      watching_first_post: :following,
      watching_category_or_tag: :following,
      private_message: :private_message,
      chat_message: :chat_message,
      chat_watched_thread: :chat_message,
      chat_mention: :chat_mention,
    }.freeze

    def self.supplemental?(notification)
      SUPPLEMENTAL_TYPES.include?(Notification.types[notification.notification_type]) ||
        calendar_change?(notification.data_hash)
    end

    def self.calendar_change?(data)
      data[:message] == "isbf_calendar.changed"
    end

    def initialize(user, notifications: [])
      @user = user
      @entries_by_id = {}
      @entries_by_topic = {}
      @channels = {}
      @original_posts = {}
      preload(notifications) if notifications.present?
    end

    def post_number_for(notification)
      if POST_EVENT_TYPES.include?(Notification.types[notification.notification_type])
        post = original_post(notification.data_hash[:original_post_id], notification.topic_id)
      end
      post&.post_number || notification.post_number
    end

    def payload_for(notification)
      data = notification.data_hash
      post_number = post_number_for(notification)
      {
        notification_type: notification.notification_type,
        topic_id: notification.topic_id,
        topic_title: notification.topic&.title.presence || data[:topic_title],
        post_number: post_number,
        post_url:
          (
            if notification.topic_id
              "/t/#{notification.topic_id}/#{post_number || 1}"
            else
              "/my/notifications"
            end
          ),
        channel_id: data[:chat_channel_id],
        notification_data: data,
      }
    end

    def enabled?(payload, web_push: false)
      return true unless SiteSetting.isbf_notifications_enabled

      type = Notification.types[payload[:notification_type]]
      setting =
        (
          if self.class.calendar_change?(payload[:notification_data] || {})
            :calendar_changed
          else
            SETTINGS[type]
          end
        )
      if setting
        return false unless SiteSetting.public_send("isbf_device_push_#{setting}")
        if setting == :scheduled_event
          return(
            scheduled_entries(payload[:topic_id]).any? do |entry|
              entry.source_item.visible_to?(@user.guardian)
            end
          )
        end
        if setting == :calendar_changed
          entry = calendar_entry(payload)
          return false unless entry&.source_item

          return entry.source_item.cancelled? || entry.source_item.visible_to?(@user.guardian)
        end

        return true
      end

      # An unlisted type keeps its existing Web Push eligibility. Direct clients
      # use the same native baseline rather than treating every site notice as push.
      web_push ||
        (PostAlerter::NOTIFIABLE_TYPES - [Notification.types[:event_invitation]]).include?(
          payload[:notification_type],
        )
    end

    def presentation(payload)
      I18n.with_locale(@user.effective_locale) do
        {
          version: SCHEMA_VERSION,
          enabled: enabled?(payload),
          title: title(payload),
          body: body(payload),
        }
      end
    end

    def web_payload(payload)
      if POST_EVENT_TYPES.include?(Notification.types[payload[:notification_type]]) &&
           (post = original_post(payload[:post_id], payload[:topic_id]))
        payload = payload.merge(post_number: post.post_number, post_url: post.url)
      end
      I18n.with_locale(@user.effective_locale) do
        payload.merge(translated_title: title(payload), excerpt: body(payload))
      end
    end

    private

    def original_post(post_id, topic_id)
      post_id = post_id.to_i
      return unless post_id.positive? && topic_id

      post =
        @original_posts.fetch(post_id) do
          @original_posts[post_id] = Post.includes(:topic).find_by(id: post_id)
        end
      post if post&.topic_id == topic_id && @user.guardian.can_see?(post)
    end

    def preload(notifications)
      calendar_ids = []
      topic_ids = []
      channel_ids = []
      original_post_ids = []
      notifications.each do |notification|
        data = notification.data_hash
        if POST_EVENT_TYPES.include?(Notification.types[notification.notification_type])
          original_post_ids << data[:original_post_id].to_i
        end
        calendar_ids << data[:entry_id] if self.class.calendar_change?(data)
        if notification.notification_type == Notification.types[:event_reminder]
          topic_ids << notification.topic_id
        end
        channel_ids << data[:chat_channel_id] if data[:chat_channel_id]
      end
      original_posts = Post.includes(:topic).where(id: original_post_ids).index_by(&:id)
      @original_posts = original_post_ids.index_with { |post_id| original_posts[post_id] }
      if defined?(::IsbfCalendar::Entry)
        entries_by_id =
          ::IsbfCalendar::Entry
            .where(user_id: @user.id, id: calendar_ids)
            .includes(source_item: { topic: :first_post })
            .index_by(&:id)
        @entries_by_id = calendar_ids.index_with { |entry_id| entries_by_id[entry_id] }
        entries =
          ::IsbfCalendar::Entry
            .joins(:source_item)
            .where(user_id: @user.id, schedule_kind: "event")
            .where(
              isbf_calendar_official_items: {
                topic_id: topic_ids,
                schedule_kind: "event",
                cancelled: false,
              },
            )
            .includes(source_item: { topic: :first_post })
            .to_a
        @entries_by_topic =
          topic_ids.index_with do |topic_id|
            entries.select { |entry| entry.source_item.topic_id == topic_id }
          end
      end
      if defined?(::Chat::Channel)
        channels = ::Chat::Channel.where(id: channel_ids).includes(:chatable).index_by(&:id)
        @channels = channel_ids.index_with { |channel_id| channels[channel_id] }
      end
    end

    def scheduled_entries(topic_id)
      @entries_by_topic[topic_id] ||= if defined?(::IsbfCalendar::Entry) && topic_id
        ::IsbfCalendar::Entry
          .joins(:source_item)
          .where(user_id: @user.id, schedule_kind: "event")
          .where(
            isbf_calendar_official_items: {
              topic_id: topic_id,
              schedule_kind: "event",
              cancelled: false,
            },
          )
          .includes(source_item: { topic: :first_post })
          .to_a
      else
        []
      end
    end

    def calendar_entry(payload)
      entry_id = (payload[:notification_data] || {})[:entry_id].to_i
      @entries_by_id.fetch(entry_id) do
        @entries_by_id[entry_id] = if defined?(::IsbfCalendar::Entry)
          ::IsbfCalendar::Entry
            .where(user_id: @user.id)
            .includes(source_item: { topic: :first_post })
            .find_by(id: entry_id)
        end
      end
    end

    def title(payload)
      value =
        if self.class.calendar_change?(payload[:notification_data] || {})
          entry = calendar_entry(payload)
          if entry&.source_item&.visible_to?(@user.guardian)
            entry.source_item.topic.title.presence || entry.title
          else
            entry&.title
          end
        elsif payload[:channel_id] && defined?(::Chat::Channel)
          channel =
            @channels.fetch(payload[:channel_id]) do
              @channels[payload[:channel_id]] = ::Chat::Channel.includes(:chatable).find_by(
                id: payload[:channel_id],
              )
            end
          channel&.title(@user)
        else
          payload[:topic_title]
        end
      CGI.unescapeHTML(ActionController::Base.helpers.strip_tags(value.to_s)).presence ||
        SiteSetting.title
    end

    def body(payload)
      type = Notification.types[payload[:notification_type]]
      key = BODY_KEYS[type]
      if self.class.calendar_change?(payload[:notification_data] || {})
        key =
          calendar_entry(payload)&.source_item&.cancelled? ? :calendar_cancelled : :calendar_changed
      elsif type == :event_reminder
        message = (payload[:notification_data] || {})[:message].to_s
        key =
          if message.include?("after_event_reminder")
            :event_after
          elsif message.include?("ongoing_event_reminder")
            :event_ongoing
          elsif message.include?("before_event_reminder")
            :event_before
          else
            event_phase(payload)
          end
      end
      I18n.t(
        "isbf_notifications.device_push.#{key || type || :generic}",
        default: I18n.t("isbf_notifications.device_push.generic"),
      )
    end

    def event_phase(payload)
      entry = scheduled_entries(payload[:topic_id]).first
      return :event_before unless entry
      return :event_after if entry.source_item.ends_at < Time.current
      return :event_ongoing if entry.source_item.starts_at <= Time.current

      :event_before
    end
  end
end
