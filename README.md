# ISBF Notifications

Groups the existing in-site notifications and provides a shared device push policy for iPhone, Google Web Push, and Android direct clients.

## Device push settings

Developers (`User#admin`) manage ten grouped switches in **Admin → Notifications → Push events**. The page uses native FormKit toggles and config cards, saves changed values together through the existing authorized site-setting endpoint, and retains the original settings under **Other notification settings**. Saving creates no user notification or email.

Requires the matching Core `admin-notification-settings` wrapper outlet. Without this outlet the original Core notifications settings page remains available. Disable `isbf_notifications_enabled` to return to the pre-existing device push behavior and ordinary notification API shape; stored settings and notifications are retained.

The switches filter Web Push at the final `PushNotificationPusher` boundary, including already queued deliveries. They do not register the shared `push_notification_filters` hook because that hook also controls in-site live alerts. In-site notification creation, unread state, live alerts, email, reminder schedules, and existing delivery transports remain unchanged.

Likes, reactions, topic reminders, calendar advance reminders, and calendar changes use the existing `PostAlerter` and delivery job when their corresponding switch permits sending. Event reminders require a currently visible activity that the recipient added to their personal schedule. Schedule changes are restricted to the recipient's own entry, including cancellation notices.

Calendar advance reminders use the existing **Scheduled events** switch and the native Web Push/Hub delivery job. The actual ISBF-Calendar reminder processor selects the channel first: entries already delivered to a verified calendar subscription do not create an in-site reminder and therefore do not create a second device push. In-site reminders retain their unread state and email suppression. Notification data updates do not send another reminder.

Queued calendar reminders are bound to the owner's entry, reminder generation, trigger time, and notification. Delivery checks the current unread record, recipient eligibility, source visibility/cancellation, reminder settings, and ten-minute catch-up window again. Rescheduling, removing the entry, disabling reminders, or reading the notice prevents stale delivery. Titles use sanitized entry names; push bodies omit notes and locations. The link opens `/isbf/calendar?entry_id=…`, and each reminder generation has a separate notification tag.

Native do-not-disturb, activity-based delay, push subscriptions, browser permission, and operating-system notification settings still apply. This integration does not promise immediate lock-screen delivery and does not change Apple Calendar refresh behavior.

`GET /notifications.json?device_push=true` adds versioned `isbf_device_push` metadata to each authorized notification. It retains every row and the existing pagination and read state so clients can advance their cursor across suppressed events. The ordinary endpoint remains unchanged. Metadata preparation batches schedule and chat associations for each page.

Android integration is documented in [the APK contract](docs/ANDROID_DIRECT_PUSH_CONTRACT.md). This change does not modify or build the APK; an old APK does not consume this policy.

## Android browser account connection

Android direct clients can connect their notification identity to one browser profile through the existing Discourse user API confirmation page. After one explicit confirmation, signing in, switching accounts, or signing out in that browser updates the device's notification grant. Other browser profiles and ordinary API clients remain independent.

The connection uses a private device bearer and RSA-encrypted, narrowly scoped grants. It does not export browser cookies to the APK or alter Web Push, email, or the shared event switches. See [the browser account protocol](docs/ANDROID_BROWSER_ACCOUNT_LINK.md) for expiry, revocation, and client requirements.

## UI reference and verification

The accepted grouped-toggle design and reuse scope are recorded in [the design specification](docs/design-system/push-event-settings.md). Server and browser validation must run in an isolated environment with independent PostgreSQL and Redis; never run these tests against production.

```sh
LOAD_PLUGINS=1 bin/rspec plugins/isbf-notifications/spec
bin/qunit --filter "DevicePushSettings"
bin/lint --fix plugins/isbf-notifications
```

Installation, tests, review, and production deployment are separate stages. No source copy or test run grants deployment authorization.

## Grouped in-site notifications

The existing grouping feature organizes Discourse notifications by topic and
action without adding tables or migrations. Enable `isbf_notifications_enabled`
after installing the matching ISBF-UI theme. Device push behavior and its Core
integration are described above.

Authenticated read APIs:

- `GET /isbf/notifications/groups.json?tab=all|mentions`: complete topic groups and
  standalone native notices, ordered by latest notification; signed cursor pagination.
- `GET /isbf/notifications/groups/:topic_id/actions/:action.json`: lazy action details.
  `limit` defaults to 20 and is capped at 50.

The mentions tab includes mentions, group mentions, replies, and reactions.
Likes/reactions use existing surviving actions on posts referenced by the recipient's
notifications, capped at the notification timestamp, and deduplicate each person per
topic/action. Other actions retain the available native notification records.
Historical cross-topic summaries remain standalone. Purged events are not reconstructed.

Both APIs enforce recipient, topic, and post visibility. Expanding groups never marks
notifications read. Navigation and bulk marking remain native Discourse operations.
Disabling the setting restores the native notification page in the matching theme.
