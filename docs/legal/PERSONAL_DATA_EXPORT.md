# Personal-data export design and operations

Status: implemented for controlled testing; production retention and fulfillment wording require owner/counsel approval.

The protected administrator approves an access-export request, which creates a durable `privacy_access_export` workload. The worker builds structured JSON plus a human-readable manifest outside the HTTP request. Queries are scoped to the requesting user and intentionally exclude password hashes, tokens, secrets, internal authorization state, other users' contact data and confidential moderation notes.

Artifacts are size-limited, hashed and encrypted using AES-256-GCM with an independent 32-byte base64 production key. The database stores metadata and the encrypted file path, not the encryption key. The configured retention reference is mandatory in production.

Download requires:

- a current authenticated session owned by the requester;
- current-password reauthentication;
- a short-lived single-use grant bound to the current session and artifact; and
- the grant in `X-Privacy-Export-Grant`, avoiding URL/proxy logging.

The server streams authenticated decryption, verifies the digest before a successful artifact is considered valid, records access, and consumes the grant. Expiry cleanup removes the encrypted artifact and records deletion. Operations must monitor failed jobs and missing/corrupt files without placing export contents in logs.
