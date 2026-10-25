# frozen_string_literal: true

class IsbfNotifications::AndroidBrowserLink::Register
  include Service::Base

  params do
    attribute :public_key, :string
    attribute :nonce, :string

    validates :public_key, presence: true, length: { maximum: 2048 }
    validates :nonce, format: { with: IsbfNotifications::AndroidBrowserLink::NONCE_PATTERN }
    validate :supported_public_key

    def supported_public_key
      key = OpenSSL::PKey::RSA.new(public_key.to_s)
      errors.add(:public_key, :invalid) if key.private? || !key.n.num_bits.between?(2048, 4096)
    rescue OpenSSL::PKey::RSAError
      errors.add(:public_key, :invalid)
    end
  end

  policy :feature_enabled
  model :registration, :prepare_registration
  step :register_device

  private

  def feature_enabled
    SiteSetting.isbf_notifications_enabled
  end

  def prepare_registration(params:)
    IsbfNotifications::AndroidBrowserLink::Registration.prepare(
      public_key: params.public_key,
      nonce: params.nonce,
    )
  end

  def register_device(registration:)
    registration.save!
  end
end
