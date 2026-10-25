# frozen_string_literal: true

class IsbfNotifications::AndroidBrowserLink::Complete
  include Service::Base

  params do
    attribute :client_id, :string
    attribute :payload, :string
    validates :client_id, :payload, presence: true
  end

  options do
    attribute :previous_browser_key, :string
    attribute :auth_token_id, :integer
  end

  model :registration
  policy :can_follow_browser
  model :client
  model :key

  transaction do
    step :restrict_device_client
    step :expire_device_key
    model :device, :create_device
    step :replace_previous_device
  end

  step :finish_registration

  private

  def fetch_registration(params:)
    IsbfNotifications::AndroidBrowserLink::Registration.for_client(params.client_id)
  end

  def can_follow_browser(guardian:, options:)
    IsbfNotifications::AndroidBrowserLink.allowed_user?(guardian.user) &&
      UserAuthToken.unexpired.where(id: options.auth_token_id, user_id: guardian.user.id).exists?
  end

  def fetch_client(params:)
    UserApiKeyClient.find_by(client_id: params.client_id)
  end

  def fetch_key(client:, guardian:)
    client.keys.active.where(user_id: guardian.user.id).order(id: :desc).first
  end

  def restrict_device_client(client:, registration:)
    client.update!(public_key: registration.data[:public_key])
    IsbfNotifications::AndroidBrowserLink::SCOPES.each do |scope|
      client.scopes.find_or_create_by!(name: scope)
    end
  end

  def expire_device_key(key:)
    key.update!(expires_at: IsbfNotifications::AndroidBrowserLink::LINK_TTL.from_now)
  end

  def create_device(registration:, key:, params:, options:)
    device =
      IsbfNotifications::AndroidBrowserLink::Device.new(
        registration.data[:digest],
        registration
          .data
          .except(:digest)
          .merge(
            status: "active",
            revision: 1,
            key_id: key.id,
            user_id: key.user_id,
            auth_token_id: options.auth_token_id,
            payload: params.payload,
            notification_cursor: Notification.where(user_id: key.user_id).maximum(:id) || 0,
            expires_at: IsbfNotifications::AndroidBrowserLink::LINK_TTL.from_now.to_i,
          ),
      )
    device.save!
    device
  end

  def replace_previous_device(device:, options:)
    previous = IsbfNotifications::AndroidBrowserLink::Device.find(options.previous_browser_key)
    previous.disconnect! if previous && previous.digest != device.digest
  end

  def finish_registration(registration:)
    registration.remove!
  end
end
