# frozen_string_literal: true

RSpec.describe IsbfNotifications::SendSupplementalPush do
  describe described_class::Contract, type: :model do
    it { is_expected.to validate_presence_of(:notification_id) }
  end

  describe ".call" do
    subject(:result) { described_class.call(params:, **dependencies) }

    fab!(:recipient, :user)
    fab!(:topic, :topic_with_op)
    fab!(:subscription) { Fabricate(:push_subscription, user: recipient) }

    let(:params) { { notification_id: notification_id } }
    let(:dependencies) { {} }
    let(:notification_id) { notification.id }
    let(:notification_type) { :liked }
    let(:notification) do
      Fabricate(
        :notification,
        user: recipient,
        topic:,
        post_number: 1,
        notification_type: Notification.types.fetch(notification_type),
        data: { topic_title: topic.title }.to_json,
      )
    end

    before do
      SiteSetting.isbf_notifications_enabled = true
      SiteSetting.isbf_device_push_liked = true
      SiteSetting.isbf_device_push_topic_reminder = true
      SiteSetting.push_notification_time_window_mins = 0
      notification
      Jobs::DeliverPushNotification.clear
    end

    context "when the contract is invalid" do
      let(:notification_id) { nil }

      it { is_expected.to fail_a_contract }
    end

    context "when the notification is missing" do
      let(:notification_id) { 0 }

      it { is_expected.to fail_to_find_a_model(:notification) }
    end

    context "when the event already has a native push path" do
      let(:notification_type) { :replied }

      it { is_expected.to fail_a_policy(:supplemental_event) }
    end

    context "when the event switch is disabled" do
      before { SiteSetting.isbf_device_push_liked = false }

      it "stops device delivery and preserves the in-site notification" do
        expect(result).to fail_a_policy(:push_enabled)
        expect(Jobs::DeliverPushNotification.jobs).to be_empty
        expect(notification.reload).to have_attributes(read: false, user_id: recipient.id)
      end
    end

    context "when the plugin is disabled" do
      before { SiteSetting.isbf_notifications_enabled = false }

      it { is_expected.to fail_a_policy(:push_enabled) }
    end

    context "when the notification was read before delivery" do
      before { notification.update!(read: true) }

      it { is_expected.to fail_a_policy(:push_enabled) }
    end

    context "when the recipient is suspended" do
      before { recipient.update!(suspended_till: 1.day.from_now) }

      it { is_expected.to fail_a_policy(:push_enabled) }
    end

    context "when the recipient has lost access to the topic" do
      before { topic.update!(category: Fabricate(:private_category, group: Fabricate(:group))) }

      it "preserves the notification record without leaking the topic through a new push" do
        expect(result).to fail_a_policy(:push_enabled)
        expect(Jobs::DeliverPushNotification.jobs).to be_empty
        expect(notification.reload.user_id).to eq(recipient.id)
      end
    end

    context "when the recipient is in do not disturb mode" do
      before { Fabricate(:do_not_disturb_timing, user: recipient, ends_at: 1.hour.from_now) }

      it "retains the native do not disturb boundary" do
        expect(result).to run_successfully
        expect(Jobs::DeliverPushNotification.jobs).to be_empty
      end
    end

    context "when the supplemental event is enabled" do
      it "enqueues one push without changing notification or email state" do
        notification_state = notification.reload.attributes
        email_count = Jobs::UserEmail.jobs.size

        expect { result }.to change { Jobs::DeliverPushNotification.jobs.size }.by(1)

        expect(result).to run_successfully
        expect(Jobs::DeliverPushNotification.jobs.last["args"].first).to include(
          "user_id" => recipient.id,
          "payload" =>
            include("topic_id" => topic.id, "notification_type" => notification.notification_type),
        )
        expect(notification.reload.attributes).to eq(notification_state)
        expect(Jobs::UserEmail.jobs.size).to eq(email_count)
      end
    end

    %i[liked_consolidated reaction topic_reminder].each do |type|
      context "when the event is #{type}" do
        let(:notification_type) { type }

        it "uses the existing push delivery job" do
          expect { result }.to change { Jobs::DeliverPushNotification.jobs.size }.by(1)
          expect(result).to run_successfully
        end
      end
    end
  end
end
