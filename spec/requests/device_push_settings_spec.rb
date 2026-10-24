# frozen_string_literal: true

RSpec.describe Admin::SiteSettingsController do
  fab!(:developer, :admin)
  fab!(:moderator)
  fab!(:user)

  describe "#update" do
    let(:settings) do
      {
        isbf_device_push_liked: {
          value: true,
        },
        isbf_device_push_replied: {
          value: false,
        },
        isbf_device_push_mentioned: {
          value: false,
        },
        isbf_device_push_following: {
          value: false,
        },
        isbf_device_push_private_message: {
          value: false,
        },
        isbf_device_push_chat_message: {
          value: false,
        },
        isbf_device_push_chat_mention: {
          value: false,
        },
        isbf_device_push_topic_reminder: {
          value: true,
        },
        isbf_device_push_scheduled_event: {
          value: false,
        },
        isbf_device_push_calendar_changed: {
          value: true,
        },
      }
    end

    before { SiteSetting.isbf_notifications_enabled = true }

    it "saves all ten device switches for a developer without generating a user notification" do
      sign_in(developer)
      notification_count = Notification.count
      email_jobs = Jobs::UserEmail.jobs.size
      push_jobs = Jobs::DeliverPushNotification.jobs.size
      alerts =
        MessageBus.track_publish do
          put "/admin/site_settings/bulk_update.json", params: { settings: }
        end

      expect(response).to have_http_status(:no_content)
      expect(settings.keys.to_h { |setting| [setting, SiteSetting.public_send(setting)] }).to eq(
        settings.transform_values { |config| config[:value] },
      )
      expect(Notification.count).to eq(notification_count)
      expect(Jobs::DeliverPushNotification.jobs.size).to eq(push_jobs)
      expect(Jobs::UserEmail.jobs.size).to eq(email_jobs)
      expect(alerts.map(&:channel).grep(%r{\A/notification-alert/})).to be_empty
    end

    it "rejects ordinary moderators without changing a device switch" do
      sign_in(moderator)

      expect do
        put "/admin/site_settings/bulk_update.json", params: { settings: }
      end.not_to change { SiteSetting.isbf_device_push_liked }
      expect(response).to have_http_status(:not_found)
    end

    it "rejects ordinary members without changing a device switch" do
      sign_in(user)

      expect do
        put "/admin/site_settings/bulk_update.json", params: { settings: }
      end.not_to change { SiteSetting.isbf_device_push_liked }
      expect(response).to have_http_status(:not_found)
    end
  end
end
