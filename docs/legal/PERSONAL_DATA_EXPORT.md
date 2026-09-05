# Personal-data export design and operations

Status: implemented for controlled testing; production retention and fulfillment wording require owner/counsel approval.

The protected administrator approves an access-export request, which creates a durable `privacy_access_export` workload. The worker builds the versioned `terraleb-personal-data-v3` human-readable HTML report outside the HTTP request. Queries are scoped to the requesting user and intentionally exclude password hashes, tokens, secrets, internal authorization state, other users' contact data and confidential moderation notes.

The downloaded report is a user-facing record, not a database or debugging dump. It excludes internal user, request, project, assignment, feature, import, export, notification, report, audit and AI identifiers; storage paths and object references; hashes and checksums; raw EXIF; raw geometry/location payloads; and other system-only metadata. Project relationships are shown by project name. Nested user-facing values are recursively scrubbed for identifier-shaped keys and UUID values, the report has no expandable technical-details section, and its filename contains no request or artifact identifier. Authorization continues to be enforced server-side; hiding identifiers is data minimization, not an access-control mechanism.

Only `terraleb-personal-data-v3` artifacts can receive or consume a download grant. A pre-v3 artifact remains encrypted until its normal retention cleanup but cannot be downloaded; the requester must create a fresh access request so the worker generates the minimized format.

Artifacts are size-limited, hashed and encrypted using AES-256-GCM with an independent 32-byte base64 production key. The database stores metadata and the encrypted file path, not the encryption key. The configured retention reference is mandatory in production.

Download requires:

- a current authenticated session owned by the requester;
- current-password reauthentication;
- a short-lived single-use grant bound to the current session and artifact; and
- the grant in `X-Privacy-Export-Grant`, avoiding URL/proxy logging.

The server streams authenticated decryption, verifies the digest before a successful artifact is considered valid, records access, and consumes the grant. Expiry cleanup removes the encrypted artifact and records deletion. Operations must monitor failed jobs and missing/corrupt files without placing export contents in logs.
