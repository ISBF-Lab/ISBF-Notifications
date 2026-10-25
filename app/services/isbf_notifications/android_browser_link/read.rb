# frozen_string_literal: true

class IsbfNotifications::AndroidBrowserLink::Read
  include Service::Base

  params do
    attribute :android_device_token, :string
    validates :android_device_token,
              format: {
                with: IsbfNotifications::AndroidBrowserLink::TOKEN_PATTERN,
              }
  end

  policy :feature_enabled
  model :device
  only_if :revoked_grant? do
    step :invalidate_grant
  end
  only_if :expired_browser_session? do
    step :pause_signed_out_browser
  end

  private

  def feature_enabled
    SiteSetting.isbf_notifications_enabled
  end

  def fetch_device(params:)
    IsbfNotifications::AndroidBrowserLink::Device.from_token(params.android_device_token) ||
      IsbfNotifications::AndroidBrowserLink::Registration.from_digest(
        ApiKey.hash_key(params.android_device_token),
      )
  end

  def revoked_grant?(device:)
    device.is_a?(IsbfNotifications::AndroidBrowserLink::Device) &&
      device.data[:status] == "active" && !device.key_valid?
  end

  def invalidate_grant(device:)
    device.invalidate_revoked_grant!
  end

  def expired_browser_session?(device:)
    device.is_a?(IsbfNotifications::AndroidBrowserLink::Device) &&
      device.data[:status] == "active" && !device.session_valid?
  end

  def pause_signed_out_browser(device:)
    device.synchronize!(nil)
  end
end
