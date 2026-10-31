# PocketTrainer iPhone release notes

## Current iPhone release - October 30, 2026

- Latest uploaded version: **1.0 (13)**, uploaded October 27, 2026.
- **TestFlight:** build 13 is approved and available for internal and external testing through the [public invitation](https://testflight.apple.com/join/PG93UveP). Check that TestFlight shows **1.0 (13)** when installing/updating.
- **App Store:** the same uploaded build was submitted October 28, 2026 at 7:51 a.m. Pacific. Its status is **Waiting for Review**, with automatic release after approval. TestFlight approval is separate from App Store approval.
- Build 13 requires iOS 16 or later. The public source snapshot below has its own build requirements and does not include every component of the submitted build.

[iPhone overview](https://luckisondu.github.io/pockettrainer-web/iphone.html) | [TestFlight instructions](https://luckisondu.github.io/pockettrainer-web/testflight.html) | [Support](https://luckisondu.github.io/pockettrainer-web/support.html) | [Contact](https://luckisondu.github.io/pockettrainer-web/contact.html) | [Privacy](https://luckisondu.github.io/pockettrainer-web/privacy.html) | [All links](https://luckisondu.github.io/pockettrainer-web/links.html)


## Version 1.0 (13)

- Home, Chat, Files and Settings navigation with project-specific chats and local project storage.
- Local training, held-out predictions and compatible model export; CPU fallback when GPU initialization/results are unavailable.
- Correct handling of very small fixed-batch datasets and quoted project names in saved configuration.
- Training curves, parameter/code views, digit drawing and project templates for supported educational datasets.
- Settings > Privacy & data and Offline learning tips; visible app version/build in About.
- Home > View all projects and Settings > Done navigation fixes.
- Direct optional account authorization on iPhone, connection guidance and local saving of completed tutor responses to Notes. Provider eligibility and live service access are required.
- Optional image generation opens its generation screen directly and needs a compatible user-supplied Core ML pack. No public converted-model pack is included.
- Updated AI-in-phone app icon.

## Validation and limits

The final candidate was installed on an iPhone 12. Eight distinct native UI flows and 25 computational/persistence checks passed across builds 12/13; the computational audit forced app network requests to fail. A synthetic photo-learning pipeline classified 15/15 held-out examples, and prepared-model image generation produced a 384 x 384 illustration on the phone. These are scoped checks, not accuracy or compatibility guarantees for every device, dataset or model.

No live paid tutor response was included in that audit. Initial dataset downloads, online searches, account authorization and the online tutor require internet. Service eligibility and account/usage restrictions apply. TestFlight's available version may take time to refresh on a tester's device; confirm the build number in TestFlight.
