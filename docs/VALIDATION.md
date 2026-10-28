# Validation

Local checks and CI do not replace real screen-recording, multi-monitor, or translation-provider verification.

- `scripts/test.sh`: image bounds and layout, OCR grouping, structured translation output, annotation export and original-image preservation.
- `scripts/test-license.sh`: activation state, product-code isolation, persistence, transient network failure, explicit revocation, account ownership, and numeric version comparisons.
- `scripts/test-lifecycle.sh`: capture cancellation, copy/close/pin, shortcut persistence and Carbon registration.
- `TRANSEEN_TEST_APPLE=1 scripts/test-lifecycle.sh`: optional real Apple Translation checks with installed language packs.

Known limits: dense layouts and inline formulas can be imperfect; specialist terms depend on the provider. Multi-monitor and physical keyboard flows need device verification. See release notes for build/signing status.
