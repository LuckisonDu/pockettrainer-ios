# PocketTrainer for iPhone: Support

## Current iPhone release - October 30, 2026

- Latest uploaded version: **1.0 (13)**, uploaded October 27, 2026.
- **TestFlight:** build 13 is approved and available for internal and external testing through the [public invitation](https://testflight.apple.com/join/PG93UveP). Check that TestFlight shows **1.0 (13)** when installing/updating.
- **App Store:** the same uploaded build was submitted October 28, 2026 at 7:51 a.m. Pacific. Its status is **Waiting for Review**, with automatic release after approval. TestFlight approval is separate from App Store approval.
- Build 13 requires iOS 16 or later. The public source snapshot below has its own build requirements and does not include every component of the submitted build.

[iPhone overview](https://luckisondu.github.io/pockettrainer-web/iphone.html) | [TestFlight instructions](https://luckisondu.github.io/pockettrainer-web/testflight.html) | [Support](https://luckisondu.github.io/pockettrainer-web/support.html) | [Contact](https://luckisondu.github.io/pockettrainer-web/contact.html) | [Privacy](https://luckisondu.github.io/pockettrainer-web/privacy.html) | [All links](https://luckisondu.github.io/pockettrainer-web/links.html)



PocketTrainer is a native iPhone learning app. Its core projects train and test small models on the phone; they do not require a laptop, a paid AI account or a server.

## Start with a learning project

1. Open Home and choose Open data mnist or Photo classifier.
2. On Training, review the dataset and editable parameters, then tap Run.
3. On Result, inspect the held-out test examples. For a trained MNIST model, draw a digit and tap Check.
4. Use Files for project files, runs and saved notes. Project chat opens the conversation attached to that project.

To make another project, use the plus button on Home. Choose a template, review the dataset, then review settings before starting training. Online dataset search and first downloads need internet; already prepared local datasets can be used offline.

## Optional connected tutor and models

The optional online tutor connects directly from this iPhone to OpenAI. Open Chat or Account, choose Continue with ChatGPT, and complete sign-in on the phone. An eligible ChatGPT plan, permission to use it in PocketTrainer, internet access and available usage are required. No computer, pairing code or Python bridge is needed. If no account is connected, sending a question shows connection instructions and a Continue with ChatGPT button in the conversation. After the user connects and authorizes plan access, the saved question is retried without duplication. Connection errors are not saved as completed answers in Notes. A renewable session refreshes automatically. The on-device coach and saved chats remain available without an online account.

Image generation projects open directly to their generation screen. Before first use, import a compatible Core ML model folder from Files in Set up models, or configure a licensed public HTTPS manifest. Original PyTorch weights are not an installable Core ML pack. The automatic public download pack is not yet supplied in this build. Existing prepared models are reused on the phone without contacting a personal server. Extra models need substantial device storage and compatible hardware. The built-in learning projects do not require these extra models.

Use Settings > Offline learning tips for local rule-based guidance. Settings > Privacy & data explains local storage, online sharing and support; its essential text is available offline.

## Troubleshooting

- For a download failure, check internet access, the source address and available storage. Image-generation download addresses must use public HTTPS; compatible folders can also be imported from Files.
- For a disconnected tutor, check internet access and ChatGPT plan permissions. Reconnect in Account if a session was revoked; OpenAI can also restrict availability by account, workspace or region.
- For interrupted training, reopen the project and use an available saved checkpoint.
- For speech input, check microphone and speech permissions and whether the selected language supports on-device recognition.
- Before removing the app, export any projects or notes you want to keep.

## Get help

Email [luckisondu@gmail.com](mailto:luckisondu@gmail.com) with the iPhone model, iOS version, PocketTrainer version/build, the action you tried and the exact error. You may attach a screenshot after removing private information. Do not send passwords, connection tokens or private datasets.

[Native iPhone privacy policy](PRIVACY_IOS.md)

## TestFlight feedback

Install/update through the [public beta invitation](https://testflight.apple.com/join/PG93UveP). Use Send Beta Feedback in TestFlight or [email luckisondu@gmail.com](mailto:luckisondu@gmail.com). Apple may share beta crash/usage reports and submitted feedback with the developer under its TestFlight privacy notice. [Current support/contact page](https://luckisondu.github.io/pockettrainer-web/contact.html).
