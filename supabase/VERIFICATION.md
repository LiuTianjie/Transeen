# Deployment verification — 2026-10-28

## Deployed

- Project: `mkbeusztkzffnzjdwmqk` (existing iTool Auth project).
- Private schema: `transeen_licensing`.
- Migration: `20261028114555_transeen_licensing` (Supabase MCP history version).
  The original CLI-created draft was renamed to match the actual applied version.
- Edge Function: `transeen-license`, version **1**, status **ACTIVE**.
- Edge ID: `d0b3d333-461d-4258-a5b4-cdd168adfb11`.
- Edge bundle SHA-256: `e5060c1ece84942abcb4eff39a1c77054aa41029852f2c87765dabfce95a0ad7`.
- Downloaded deployed function source matches the local entrypoint exactly.
- Existing Google/GitHub/email providers remain enabled. The user added
  `transeen://auth-callback`; the Auth API subsequently accepted it in a generated
  link. No email was sent and no provider settings were changed by this work.

## Production inventory

The initial batch contains **100 available** codes,
**0 activated**, **0 revoked**. There is one production batch and no activation
history. The private local TXT contains 100 unique codes, exactly matching the
remote codes and hashes, with file mode `0600`. No pending generation journals
remain. Plaintext codes and private output paths are not part of this repository.

## Verified against the live service

The concentrated verification run passed **72 checks** using a separate
12-code batch and five temporary Auth users. It covered:

- Idempotent batch creation, simulated lost response/replayed journal, private
  TXT export, manifest mismatch and batch ID conflict rejection.
- Administrator list pagination, totals and exact code/hash lookup.
- Anonymous denial for every management, installation and account RPC;
  ordinary accounts denied management queries; private inventory absent from
  the public Data API; private schema usage denied to both client roles.
- Missing/invalid API key, method, oversized body, malformed installation and
  malformed receipt handling.
- Normalized code activation, installation receipt validation, idempotent retry
  and rejection from another installation.
- Six installations racing for one code; two codes racing for one installation;
  two accounts racing to claim one receipt; two accounts redeeming one code;
  two codes racing for one account. Each case preserves one live seat.
- Claim requires the original installation hash; another user cannot see or
  claim the owner's entitlement; claimed receipts require account authentication.
- Fresh password login through Supabase Auth restores the same claimed receipt
  without an installation ID. Auth refresh-token rotation preserves recovery.
- Direct account redemption and retry are idempotent; an entitled account
  cannot consume another unused code.
- Revoke disables the code and account entitlement. Reset returns the code to
  available and permits a new receipt, while every old receipt remains revoked.
- SM/IT prefixes rejected by Transeen; TR prefix rejected by StupidMirror before
  its database RPC; the new callback URL accepted and existing providers enabled.

Additional SQL checks ran in a rolled-back transaction: actual existing SM/IT
hashes cannot activate Transeen; attempt 21 exceeds the 20/hour subject limit;
expiry cleanup removes at most 100 buckets per call. No production inventory
was used for validation.

This proves API/account recovery, not a real Google/GitHub browser login,
mailbox OTP delivery, native callback delivery, or an end-to-end macOS app run.
Those client/device checks remain with the main app work.

## Advisors

Both security and performance advisors ran after deployment.

- **Intentional security WARN (3 functions):** the authenticated
  `transeen_*_for_user` RPCs use `SECURITY DEFINER` to access the private schema.
  Each uses only `auth.uid()` for the account principal, fixes `search_path`, and
  rejects missing identity. Permission, ownership and concurrency checks passed.
  [Advisory details](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).
- **Intentional INFO (4 tables):** RLS enabled with no client policies. These
  non-exposed tables deliberately deny direct client access.
  [Advisory details](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).
- **INFO (3 indexes):** new foreign-key indexes had no recorded use at this small
  inventory size. They are retained to cover history and foreign-key lookups.
  No missing foreign-key index is reported for Transeen.
  [Advisory details](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index).

There are no Transeen anonymous-definer, mutable-search-path, or performance
WARN findings. Pre-existing findings in other products and the project's existing
password-protection configuration were not changed.

## Cleanup and boundaries

The dedicated test batch, its codes and all activation history were deleted.
All five temporary Auth users and their sessions were deleted. Test rate-limit
rows were removed with exact snapshot matching. Final counts: zero test batches,
test users, test sessions, activation rows and rate-limit rows.

StupidMirror code and activation fingerprints and iTool code fingerprints are
unchanged. No StupidMirror source, native app source, iTool source, provider
configuration, Git commit or release action was changed here. The local test
script, journals, duplicate test TXT and downloaded documentation were removed;
the permanent generator and formal inventory TXT were retained.
