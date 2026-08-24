# Draft Apple privacy and Google Play Data Safety mapping

These are engineering answers, not store submissions. Reconcile them against
the final binary, backend, enabled SDKs, vendor contracts and store definitions.

| Data category | Collected/shared behavior to evaluate | Purpose | User control/deletion notes |
|---|---|---|---|
| Name | Account/profile and project attribution | Account/app functionality | Correction request; proposed deletion erases the full profile name and uses a masked label only for approved retained records |
| Email | Login, verification, recovery and security mail | Authentication/account management | Removed by completed deletion; exact operational retention requires approval |
| Phone | Required signup/contact assurance | Account/security | Removed by completed deletion; necessity for viewers requires owner review |
| User ID | Primary account/project attribution and session binding | App functionality/security | Internal UUID may remain only for approved record integrity in a non-authenticatable tombstone; not publicly exposed as an identity |
| Precise location | Geometry, GPS accuracy, photo/location context | Core GIS field collection | Foreground/user-initiated; project purpose controls required |
| Photos | Feature evidence and offline drafts | Core functionality/review | Camera/gallery choice; private storage and deletion rules required |
| Files/documents | GIS imports and generated exports | Import/export functionality | User initiated; licenses and retention required |
| Other user content | Attributes, comments, review notes, form values | Collaboration/GIS workflows | Moderation/publication rules required |
| Device identifiers | FCM registration token/device label | Push notifications | Push is optional and device registration can be removed |
| App activity/security | Audit actions, request/security events, delivery state | Security, fraud prevention and operations | No advertising/behavioral analytics found |
| Diagnostics | Redacted application/server logs and metrics | Reliability/security | Mobile intentionally avoids persistent diagnostic upload |

## Mandatory validation before submission

- Run resolved mobile dependency and container SBOM/license scans.
- Confirm whether each recipient is a processor/service provider or a store
  policy "sharing" recipient under the relevant form definitions.
- Confirm data encryption in transit/at rest and deletion behavior with evidence.
- Confirm account-deletion public URL and in-app initiation.
- Verify permissions in the actual signed AAB/IPA, not only source manifests.
- Verify Firebase, map, mail, SMS, AI, crash/support and analytics configuration.
- Preserve screenshots/exported form answers with the release evidence.
