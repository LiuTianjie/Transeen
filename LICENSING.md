# Transeen activation

The official Transeen app requires a **TR- activation code** to capture, annotate,
import, and translate images. Each code grants one perpetual entitlement.
StupidMirror **SM-** codes and iTool Pro **IT-** codes do not activate Transeen.

Enter your code in **激活与账号…** to activate this Mac without signing in.
The app stores a random installation ID and receipt in macOS Keychain, without
reading hardware serial numbers. Temporary network failures preserve a valid
cached activation; the app checks it again periodically. A revoked license stops
working after the next successful server check.

You can optionally sign in with your existing iTool Google, GitHub, or email
account and bind this Mac's license. Sign in to the same account to restore it
later. Account binding does not create an additional license.

The source code is licensed under [MIT](LICENSE), including commercial use.
The MIT license does not provide access to the official hosted activation
service. Independent distributions can configure their own backend.

For activation-code availability, visit the [product website](https://transeen.itool.tech/#activate).
For the server contract and operating model, see [supabase/README.md](supabase/README.md).
