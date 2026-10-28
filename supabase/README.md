# Transeen licensing service

Transeen has its own `TR-` activation codes and perpetual entitlement. It shares
the iTool Auth project (`mkbeusztkzffnzjdwmqk`), but never grants or consumes
StupidMirror (`SM-`) or iTool Pro (`IT-`) entitlements.

## API contract

`POST https://mkbeusztkzffnzjdwmqk.supabase.co/functions/v1/transeen-license`
requires the public app `apikey`. Gateway JWT verification is disabled because
unsigned-in installations must activate; the handler checks the configured
publishable key and the code/receipt acts as the license credential. The public
key is not a secret or a defense against a modified app. Server credentials are
read only inside Edge Functions and the administrator environment.

| Action | JSON fields |
| --- | --- |
| `activate` | `action`, `installation_id` (random UUID), `code`, optional `app_version` |
| `validate` | `action`, `installation_id`, `receipt`, optional `app_version` |

The server hashes the lowercase installation UUID with SHA-256. Codes are
normalized to uppercase with spaces/hyphens removed before hashing. A code is
`TR-` followed by six groups of four characters from
`23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (120 CSPRNG bits).

Successful responses contain `ok`, `valid`, `active`, `receipt`, `server_time`,
`principal` (`installation` or `account`), and `needs_claim`. Installation
activation and account redemption are idempotent for the same owner/code.

Accounts call PostgREST with the public `apikey` and their Auth bearer token:

| RPC | Arguments |
| --- | --- |
| `transeen_redeem_for_user` | `p_code_hash` |
| `transeen_claim_for_user` | `p_receipt`, `p_installation_hash` |
| `transeen_entitlement_for_user` | none |

The account principal comes exclusively from `auth.uid()`. Claiming changes the
existing seat's owner; it does not mint another seat. Account recovery needs only
a fresh login, not an installation UUID or the original activation code.
An account-bound receipt cannot be validated through the unsigned-in Edge path.
An inactive account returns `{ok: true, active: false, valid: false, ...}`.

`invalid_receipt`, `license_revoked`, and `claim_required` are terminal responses
for the local installation receipt. Rate limiting and temporary transport/service
failures are not revocation. The existing client retains its cached authorization
on temporary failures and validates in the background (24-hour interval). There
is no offline-expiration or forced account-claim deadline. Consequently, revocation
takes effect when the client next successfully checks the server, not instantly
on an offline Mac.

## Isolation and concurrency

The non-exposed `transeen_licensing` schema holds batches, plaintext codes plus
hashes (for the existing iTool admin view), activation history and rate buckets.
All four tables have RLS enabled with no client policies; anonymous/authenticated
roles have no schema/table access. Only the three account RPCs are executable by
authenticated users. Installation and administrator RPCs are service-role-only.
Every definer function pins `search_path` and uses explicit schema references.

Unique live-seat indexes enforce one seat per code, one installation seat per
installation hash, and one seat per account. Advisory locks serialize each owner;
code rows are locked before activation rows so claim, validation, reset and revoke
have a consistent lock order. Historical revoked receipts remain revoked forever.
Full foreign-key indexes also cover revoked history.

Rate limits are per UTC hour: activation 20/network subject and 2,000 globally;
installation validation 300/subject and 20,000 globally; redeem/claim 20/account
and 2,000 globally; account validation 300/account and 20,000 globally. Network
subjects are HMAC hashes of trusted Edge address metadata, not plaintext IPs.
At most 100 expired buckets older than two days are removed per limiter call.

## Operations

The iTool administrator backend uses:

- `transeen_ops_code_stats()`
- `transeen_ops_list_batches(p_limit, p_offset)`
- `transeen_ops_list_codes(p_status, p_batch_id, p_code_hash, p_limit, p_offset)`
- `transeen_ops_create_batch(p_batch_id, p_payload_digest, p_code_hashes, p_codes)`
- `transeen_ops_reset_code(p_code_hash)`
- `transeen_ops_revoke_code(p_code_hash)` (also available to the local CLI)

`create_batch` verifies the code/hash pairing and the SHA-256 of sorted hashes
joined by newlines, including a trailing newline. Replaying a batch ID with the
same digest returns the existing batch. A different payload returns
`batch_conflict`. Codes are never returned by installation/account endpoints.

`revoke` revokes live receipts and blocks the code. `reset` revokes live receipts
and returns the code to `available`; it can also restore an explicitly revoked
code. A later activation/redemption gets a new receipt. There is no legacy
StupidMirror `account_only` migration state in this independent schema.

The local administrator command is intentionally outside this repository:

```sh
~/.local/bin/transeen-codes 100
~/.local/bin/transeen-codes stats
~/.local/bin/transeen-codes reset
~/.local/bin/transeen-codes revoke
```

Reset/revoke prompt for the code without echoing it and ask for confirmation.
Generation writes `0600` TXT files under
`~/.local/state/transeen-license-admin/output/`. Pending journals are fsynced
before submission; rerunning completes pending batches before generating any new
batch. Credentials come from `TRANSEEN_SERVICE_ROLE_KEY` or the existing local
iTool `.env.local`, whose project URL is checked. They are not copied into this
repository, generated files, or command output. Keep output files and pending
journals private and out of Git.

## Deployment and Auth

Deploy only the Transeen migration and `transeen-license` function to the shared
project. This directory is not a complete migration history for iTool; do not run
an unreviewed whole-project `db push` from this checkout. Do not reapply the
greenfield migration to an initialized schema. Future DDL changes need additive
migrations created using `supabase migration new`.

Google, GitHub and email providers are the existing iTool configuration. Preserve
all providers and existing redirect URLs. `transeen://auth-callback` must be in
the additional redirect allowlist. No provider secrets belong in the app.

Production codes must not be consumed for smoke tests. Use a dedicated temporary
batch and temporary Auth users, then delete only those test activations, codes,
batch, sessions/users and rate buckets. Keep a sanitized verification record;
delete local test journals, credentials, duplicate exports and build artifacts.
