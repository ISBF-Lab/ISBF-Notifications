# frozen_string_literal: true

class IsbfNotifications::AndroidBrowserLink::Synchronize
  include Service::Base

  params do
    attribute :browser_key, :string
    validates :browser_key, format: { with: IsbfNotifications::AndroidBrowserLink::TOKEN_PATTERN }
  end

  options { attribute :auth_token_id, :integer }

  policy :feature_enabled
  model :device
  policy :browser_is_paired
  step :synchronize_account

  private

  def feature_enabled
    SiteSetting.isbf_notifications_enabled
  end

  def fetch_device(params:)
    IsbfNotifications::AndroidBrowserLink::Device.find(params.browser_key)
  end

  def browser_is_paired(device:)
    device.following?
  end

  def synchronize_account(device:, guardian:, options:)
    device.synchronize!(guardian.user, auth_token_id: options.auth_token_id)
  end
end
