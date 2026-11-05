# Transeen membership

The official Transeen app is included in the **iTool yearly membership**: CNY 99 a
year for every iTool product. Capture, markup, image import and translation require
signing in to an iTool account (Google, GitHub or email) whose membership includes
Transeen. The monthly membership (CNY 9.9) covers the iTool website and LinkShell,
not Transeen. [Get the yearly membership on itool.tech](https://itool.tech/pro?from=transeen);
payment is with Alipay.

Sign in from **账号与会员…** (Account & Membership…) in the menu bar. The window
shows your tier and expiry, offers an upgrade to monthly members, and has a
**Refresh Membership** button for after you pay.

## How the check works

Transeen asks `https://itool.tech/api/membership/entitlement?product=transeen` with
your sign-in token, which works on networks that block supabase.co. If that address
cannot be reached, it asks the `itool_entitlement` RPC on Supabase directly. It
checks on launch, when the app becomes active, after the Mac wakes, when the network
returns, and before using a result older than six hours.

After a successful check with an active membership, the app keeps the result in the
macOS Keychain and works offline for up to **7 days**, never past the end of the
membership. A clock set back before a time the app has already seen requires a new
check. When the server says the membership is not active (a refund, or a lapsed
membership), the gate closes immediately. Signing out deletes the cached result.
Transeen never reads hardware serial numbers.

## Activation codes

TR- activation codes are no longer sold or accepted, and 0.15.0 removes code
activation from the app. Codes that had been bound to an iTool account were
converted to yearly memberships on that account. If you activated a Mac without
binding an account, contact the developer with your code.

## Source license

The source code is licensed under [MIT](LICENSE), including commercial use. The MIT
license does not provide access to the hosted iTool account and membership service.
Independent distributions can configure their own backend. The legacy activation
server code is described in [supabase/README.md](supabase/README.md).
