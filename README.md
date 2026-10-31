# PocketTrainer for iPhone

**Your phone. Your AI lab.** A free student learning project by Luckison Du for Congressional App Challenge 2026.

## Current iPhone release - October 30, 2026

- Latest uploaded version: **1.0 (13)**, uploaded October 27, 2026.
- **TestFlight:** build 13 is approved and available for internal and external testing through the [public invitation](https://testflight.apple.com/join/PG93UveP). Check that TestFlight shows **1.0 (13)** when installing/updating.
- **App Store:** the same uploaded build was submitted October 28, 2026 at 7:51 a.m. Pacific. Its status is **Waiting for Review**, with automatic release after approval. TestFlight approval is separate from App Store approval.
- Build 13 requires iOS 16 or later. The public source snapshot below has its own build requirements and does not include every component of the submitted build.

[iPhone overview](https://luckisondu.github.io/pockettrainer-web/iphone.html) | [TestFlight instructions](https://luckisondu.github.io/pockettrainer-web/testflight.html) | [Support](https://luckisondu.github.io/pockettrainer-web/support.html) | [Contact](https://luckisondu.github.io/pockettrainer-web/contact.html) | [Privacy](https://luckisondu.github.io/pockettrainer-web/privacy.html) | [All links](https://luckisondu.github.io/pockettrainer-web/links.html)


## Learn on your phone

- Train small models, adjust readable parameters, and inspect training/validation curves.
- Try held-out predictions and handwritten-digit recognition after preparing a supported dataset.
- Keep project files, run records and notes together; export supported models.
- Use bundled photo projects, prepared data, local tips and saved work offline.
- Use optional online dataset/project search and an optional directly connected tutor when internet and eligible account access are available.
- Optional image generation runs locally after importing a compatible Core ML model pack; a public download pack is not included.

Core learning does not require a developer computer, pairing code, Python bridge or online AI subscription. Online tutor access is optional and subject to provider eligibility, authorization and usage limits.

## Documentation

- [Current native app overview](NATIVE_IOS.md)
- [Support](SUPPORT_IOS.md) and [privacy policy](PRIVACY_IOS.md)
- [Build 13 release notes](RELEASE_NOTES.md)
- [All public project links](https://luckisondu.github.io/pockettrainer-web/links.html)
- [Historical measured experiments](VERIFY.md) and [AI assistance disclosure](AI_DISCLOSURE.md)

## Public source scope

This repository contains an earlier educational source snapshot. It does **not** reproduce every component of the current TestFlight/App Store candidate. Private runtime components and converted model packs are not published here. Historical source, results and experiment documentation retain their original conditions; their earlier screens and requirements may differ from build 13. See the current native overview for release behavior.

To build this public snapshot, inspect `project.yml`, install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate`, open the generated Xcode project, select your development team and run on a compatible physical iPhone. The public snapshot's settings, rather than the binary release requirements above, determine that build's deployment target. The built-in trainer uses supported recipe parameters; downloaded Python code is displayed for learning, not executed.

## Related editions

[Browser demo](https://luckisondu.github.io/pockettrainer-web/) | [Web repository](https://github.com/LuckisonDu/pockettrainer-web) | [Android repository](https://github.com/LuckisonDu/pockettrainer-android)

Contact: [luckisondu@gmail.com](mailto:luckisondu@gmail.com).
