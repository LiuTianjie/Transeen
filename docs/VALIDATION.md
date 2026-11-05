# Validation

Local checks and CI do not replace real screen-recording, multi-monitor, or translation-provider verification.

- `scripts/test.sh`: image bounds and layout, OCR grouping, structured translation output, annotation export and original-image preservation.
- `scripts/test-license.sh`: membership gate states (signed out, yearly, monthly, free), the 7-day offline window and `valid_until`, clock rollback, explicit revocation, the 401 token refresh and retry, sign-out and account switches, the itool.tech client with its Supabase fallback, and numeric version comparisons.
- `scripts/test-lifecycle.sh`: capture cancellation, copy/close/pin, shortcut persistence and Carbon registration.
- `scripts/test-capture-tools.sh`: scrolling overlap and size caps, recent-capture retention and flattened privacy redactions.
- `scripts/test-annotation-editing.sh`: multiline text editing, selection and export behavior.
- `TRANSEEN_TEST_APPLE=1 scripts/test-lifecycle.sh`: optional real Apple Translation checks with installed language packs.

Known limits: dense layouts and inline formulas can be imperfect; specialist terms depend on the provider. Multi-monitor and physical keyboard flows need device verification. See release notes for build/signing status.
