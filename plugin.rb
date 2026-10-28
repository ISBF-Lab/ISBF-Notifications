# frozen_string_literal: true

# name: isbf-notifications
# about: Groups native notifications by topic and action.
# version: 0.3.0
# authors: ISBF Lab
# url: https://github.com/ISBF-Lab/ISBF-Notifications
# required_version: 3.2.0

enabled_site_setting :isbf_notifications_enabled

register_site_setting_area "device_push_events"
register_asset "stylesheets/common/device-push-settings.scss", :admin

after_initialize do
  module ::IsbfNotifications
    BADGE_STYLE_FIELD = "isbf_notification_badge_style"
    BADGE_STYLES = %w[number dot].freeze
    FILTER_FIELD = "isbf_notification_filter"
    FILTERS = %w[all unread].freeze

    class Engine < ::Rails::Engine
      engine_name "isbf-notifications"
      isolate_namespace IsbfNotifications
    end
  end
  require_relative "lib/isbf_notifications/grouped_notifications"
  require_relative "lib/isbf_notifications/calendar_reminder_push"
  require_relative "lib/isbf_notifications/device_push_policy"
  require_relative "lib/isbf_notifications/device_push_extensions"
  require_relative "app/services/isbf_notifications/send_supplemental_push"
  require_relative "lib/isbf_notifications/android_browser_link"
  require_relative "lib/isbf_notifications/android_browser_hooks"
  require_relative "app/services/isbf_notifications/android_browser_link/register"
  require_relative "app/services/isbf_notifications/android_browser_link/complete"
  require_relative "app/services/isbf_notifications/android_browser_link/synchronize"
  require_relative "app/services/isbf_notifications/android_browser_link/read"
  require_relative "app/services/isbf_notifications/android_browser_link/disconnect"
  require_relative "app/controllers/isbf_notifications/android_browser_links_controller"

  ::UserApiKeysController.prepend(IsbfNotifications::AndroidBrowserLink::Authorization)
  ::Auth::DefaultCurrentUserProvider.prepend(IsbfNotifications::AndroidBrowserLink::BrowserSession)
  Rails.application.config.filter_parameters += [:android_device_token]

  ::PushNotificationPusher.singleton_class.prepend(IsbfNotifications::DevicePushPusher)
  reloadable_patch do
    ::Jobs::DeliverPushNotification.prepend(IsbfNotifications::CalendarReminderDelivery)
  end
  ::NotificationsController.prepend(IsbfNotifications::DevicePushNotificationsController)

  add_to_serializer(:notification, :post_number) do
    policy = @options[:isbf_device_push_policy]
    policy ? policy.post_number_for(object) : object.post_number
  end

  add_to_serializer(
    :notification,
    :isbf_device_push,
    include_condition: -> { @options[:isbf_device_push_policy].present? },
  ) do
    policy = @options[:isbf_device_push_policy]
    policy.presentation(policy.payload_for(object))
  end

  on(:notification_created) do |notification|
    if SiteSetting.isbf_notifications_enabled &&
         IsbfNotifications::DevicePushPolicy.supplemental?(notification)
      IsbfNotifications::SendSupplementalPush.call(params: { notification_id: notification.id })
    end
  end

  add_model_callback(:notification, :after_update_commit) do
    if SiteSetting.isbf_notifications_enabled && saved_change_to_data? &&
         !IsbfNotifications::DevicePushPolicy.calendar_reminder?(self) &&
         IsbfNotifications::DevicePushPolicy.supplemental?(self)
      IsbfNotifications::SendSupplementalPush.call(params: { notification_id: id })
    end
  end

  register_user_custom_field_type(IsbfNotifications::BADGE_STYLE_FIELD, :string, max_length: 6)
  register_editable_user_custom_field(IsbfNotifications::BADGE_STYLE_FIELD)
  register_user_custom_field_type(IsbfNotifications::FILTER_FIELD, :string, max_length: 6)
  register_editable_user_custom_field(IsbfNotifications::FILTER_FIELD)

  add_model_callback(:user, :validate) do
    next if custom_fields_clean?

    style = custom_fields[IsbfNotifications::BADGE_STYLE_FIELD]
    if !style.nil? && IsbfNotifications::BADGE_STYLES.exclude?(style)
      errors.add(:base, I18n.t("isbf_notifications.invalid_badge_style"))
    end

    filter = custom_fields[IsbfNotifications::FILTER_FIELD]
    if !filter.nil? && IsbfNotifications::FILTERS.exclude?(filter)
      errors.add(:base, I18n.t("isbf_notifications.invalid_filter"))
    end
  end

  add_to_serializer(:current_user, :isbf_notification_badge_style) do
    object.custom_fields[IsbfNotifications::BADGE_STYLE_FIELD] == "dot" ? "dot" : "number"
  end

  add_to_serializer(:current_user, :isbf_notification_filter) do
    object.custom_fields[IsbfNotifications::FILTER_FIELD] == "unread" ? "unread" : "all"
  end

  class ::IsbfNotifications::GroupsController < ::ApplicationController
    requires_login
    requires_plugin "isbf-notifications"

    def index
      render json: service.groups(cursor: params[:cursor], limit: page_limit)
    end

    def show
      topic_id = Integer(params[:topic_id], exception: false)
      raise Discourse::InvalidParameters.new(:topic_id) unless topic_id&.positive?
      render json:
               service.details(
                 topic_id: topic_id,
                 action: params[:notification_action],
                 cursor: params[:cursor],
                 limit: page_limit,
               )
    end

    private

    def page_limit
      fetch_limit_from_params(default: 20, max: 50)
    end

    def service
      raise Discourse::NotFound unless SiteSetting.isbf_notifications_enabled
      guardian.ensure_can_see_notifications!(current_user)
      IsbfNotifications::GroupedNotifications.new(
        current_user,
        guardian,
        tab: params[:tab] || "all",
        filter: params[:filter] || "all",
      )
    end
  end

  IsbfNotifications::Engine.routes.draw do
    post "/android-browser-links" => "android_browser_links#create"
    post "/android-browser-links/poll" => "android_browser_links#poll"
    post "/android-browser-links/disconnect" => "android_browser_links#destroy"
    get "/groups" => "groups#index"
    get "/groups/:topic_id/actions/:notification_action" => "groups#show"
  end
  Discourse::Application.routes.append do
    mount ::IsbfNotifications::Engine, at: "/isbf/notifications"
  end
end
