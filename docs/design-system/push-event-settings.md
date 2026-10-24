# Device push settings

Scope: the grouped switches and message previews in the developer notifications section. This specification does not promote the full admin area or other notification interfaces into a site-wide visual reference.

## Reference and user decisions

The user selected the grouped native FormKit toggle form at `/admin/plugins/discourse-academy-roles/moderator-permissions` as the reference. The notification review prototype was accepted with one correction: omit its explanation about initial iPhone values and simulated notifications from the formal page. Saving a switch must not create a user-facing notification about the setting change.

The feature has ten shared switches, grouped as post activity, personal messages and chat, and schedule and reminders. They apply to iPhone, Google Web Push, and Android direct notifications. In-site notifications and email retain their original rules. Only activities added to the user's personal schedule qualify for activity reminders.

## Components and tokens

- Use `DPageHeader` with the existing developer/notifications breadcrumb and native navigation container.
- Use `DPageSubheader` for the section introduction, `AdminConfigAreaCard` for each group, and FormKit `toggle`, `Actions`, `Submit`, `Button`, and `Alert` for controls and status.
- Bind `DToggleSwitch` to each FormKit field's value and setter, with its field ID, translated accessible name, description, and disabled state. Inherit the installed appearance and keyboard behavior: 45 × 24 px track, 18 px knob, palette-based accent and an explicit check mark.
- Reuse the reference form's full-width toggle field within each card. Do not introduce global overrides for FormKit or the admin shell.
- Colors follow `--primary`, `--secondary`, `--tertiary`, and existing component tokens. The same rules follow the current light or dark palette.
- Keep text and descriptions flexible on narrow screens. Message titles wrap without horizontal overflow.

## Interaction and access

The default tab displays the switches. Message preview shows operation-only text with no reply, message, or chat body. The original native notifications settings remain reachable under their own tab.

Draft changes stay local until the developer saves. Switching between push events and message preview retains drafts. Save is disabled while unchanged, and discard restores the last successful values. A successful save produces only an inline admin confirmation and a screen-reader announcement. Failures retain the edits and use the native error presentation.

Only developers (`admin`) see these controls; saving uses the existing server-enforced site-setting authorization. Moderators and members do not gain access through the frontend.

## Validation boundaries

Verify the exact native implementation on desktop and mobile, light and dark palettes, keyboard toggles, save/discard, reload persistence, failure handling, and developer/moderator/member boundaries. Verify that saving does not enqueue device delivery or email and does not create an in-site record.

The accepted standalone prototype establishes design intent. It does not establish server integration, exact native rendering, device delivery, APK integration, or production deployment.
