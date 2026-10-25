# Android browser account connection

Protocol version: 1. Requires the matching Android direct client. The Google edition continues to use Chrome Web Push.

## First connection

1. The native client creates a 2048–4096-bit RSA key and a random 32-character lowercase hexadecimal nonce. It POSTs JSON `public_key` and `nonce` to `/isbf/notifications/android-browser-links.json`.
2. A 201 response supplies `client_id`, a 64-character `android_device_token`, a public `verification_url`, and the registration lifetime. The device keeps the bearer private and encrypted; it must never appear in a browser URL, clipboard, or diagnostic report.
3. The client opens the returned `/user-api-key/new` page in the selected browser. Discourse reuses that browser's login. The member checks the current account and confirms the existing Core permission prompt once. This connection permits following future logins in that browser profile.
4. Successful consent stores an encrypted, HttpOnly, SameSite=Lax browser cookie. The browser receives an application return link containing no credential. If automatic return is unsupported, the member returns to the APK manually.
5. The client POSTs its bearer as `android_device_token` to `/isbf/notifications/android-browser-links/poll.json`. It verifies the matching client, protocol, revision, and decrypted nonce before accepting a grant. It confirms the new user through `/session/current.json` before replacing the local account.

Consent remains protected by the normal Core CSRF and session checks. An API key cannot approve a browser connection. The registered public key, nonce, server-selected application name, OAEP padding, and fixed `notifications,session_info` scopes must match; `push_url` and `auth_redirect` are rejected for this flow. The application name explicitly describes following this browser's account. Other Core clients keep their existing behavior.

## Following the browser

- A successful login or linked-account switch in the paired browser revokes that device client's old grant and creates a new scoped grant. A different browser cookie profile cannot control the pairing.
- Sign-out revokes the current grant and returns `signed_out`. The pairing remains available for a later login. The APK must clear its old identity and notifications while retaining the user's reception preference.
- An expired or invalid browser session pauses the identity. A manually revoked grant is terminal and cannot be recreated by a later login without a new explicit connection.
- Reconnecting replaces the previous device pairing from that browser. The client also attempts to revoke its previous device bearer or legacy notification grant.
- Browser account hooks are best effort and must never interrupt the forum's own login or logout. Errors attempt to pause the device identity and log only the error class.

The supported states are `pending`, `active`, `signed_out`, `revoked`, and `expired`. Registration expires after 10 minutes; the browser connection and its scoped grants expire after 90 days. Device metadata stores the bearer hash and encrypted grant payload, rather than the raw bearer or raw user API key.

Each poll response includes `version`, `client_id`, `status`, and `revision`. Granted or paused device records also include an RSA-OAEP encrypted `payload`; its JSON contains the original nonce and either the scoped `key` or a pause marker. An active record includes `notification_cursor`, the recipient's high-water notification ID at the moment of connection or account switch.

Clients discard older revisions and never change identity at the same active revision. Before applying a new identity, they verify the user, replace credentials atomically, invalidate in-flight work from the previous identity, clear previous notifications, and initialize the new cursor from the supplied high-water mark. Events created after the switch remain eligible for retrieval. The existing [device push metadata contract](ANDROID_DIRECT_PUSH_CONTRACT.md) still governs presentation and event filtering.

## Background behavior and disconnection

The Android client checks an active pairing periodically and refreshes immediately after a revoked API grant returns 401/403. A signed-out client checks for a later login without querying forum notifications. These requests share the existing persisted daily budget. The implementation does not promise instantaneous account switching: network delays and Android background limits still apply.

`POST /isbf/notifications/android-browser-links/disconnect.json` with the private bearer revokes only that device client's grants. The server responds with useful JSON confirmation. A missing or expired pending bearer returns 404. JSON native endpoints do not use browser cookies for authorization; only those bearer-specific endpoints skip CSRF.

Choosing a different browser in the APK stops reception until that browser is connected. Force-stopping the app suspends local synchronization until it is opened again. Deleting browser cookies does not itself send a server event; a new connection may be required. Clearing APK data or uninstalling does not automatically revoke the server record, which can also be revoked from the forum account's application security settings.

This protocol adds no notification events, Web Push subscriptions, email deliveries, global routing changes, or database migrations.
