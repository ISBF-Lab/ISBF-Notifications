# frozen_string_literal: true

class IsbfNotifications::AndroidBrowserLink::Disconnect
  include Service::Base

  params do
    attribute :android_device_token, :string
    validates :android_device_token,
              format: {
                with: IsbfNotifications::AndroidBrowserLink::TOKEN_PATTERN,
              }
  end

  model :device
  step :disconnect_device

  private

  def fetch_device(params:)
    IsbfNotifications::AndroidBrowserLink::Device.from_token(params.android_device_token)
  end

  def disconnect_device(device:)
    device.disconnect!
  end
end
