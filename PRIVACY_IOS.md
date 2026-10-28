# PocketTrainer for iPhone: Privacy

Updated October 27, 2026. This page describes the native iPhone app, rather than its separate browser demonstration.

## On your iPhone

Training, model checks, checkpoints and prepared-model inference run on the iPhone. Projects, selected photos, imported datasets, notes, settings, generated pictures and run history are stored in the app's local files. The developer does not operate an advertising, analytics or tracking service for PocketTrainer. The app has no developer-operated user account system.

You can delete projects and notes in the app. Removing the app removes its local app data; exported files and backups are separate copies controlled by you and your device's backup settings.

## Optional online features

- Dataset and project search contacts GitHub or Hugging Face when requested. Those services receive the search or download request and normal network information, such as an IP address, under their own policies. Downloaded source files are displayed for learning; the app does not execute downloaded Python code.
- Optional model preparation imports a compatible pack from Files or downloads it from a user-configured public HTTPS source. The source receives normal download requests. Once a supported model is prepared, its inference runs on the phone. Local training and inference do not send your images to the developer.
- The optional online AI tutor connects directly from the iPhone to OpenAI using the user's own eligible ChatGPT account. It sends the question, recent chat messages, and any project context the user chooses to share, such as settings, code or note excerpts, and training results. The app asks for sharing permission before the first online request. OpenAI processes submitted text under its own policies, plan limits and account settings. No personal computer or Python bridge is used. The on-device rule-based coach does not send questions to OpenAI.
- Sign-in uses OpenAI's system-browser authorization flow. Account identity and connection tokens are stored in this iPhone's Keychain; they are not sent to the developer. Use Sign out in Account to clear local connection credentials and request session revocation. If revocation cannot be confirmed, disconnect PocketTrainer in ChatGPT Settings. iOS Keychain entries can survive app removal, so sign out before removing the app if you want to clear that connection.
- The separate Open in ChatGPT handoff lets you review text before opening it in ChatGPT. Text you choose to submit is processed by that service under its own policies.

Completed tutor responses may be saved in the relevant project's Notes, or General notes. This local note-saving feature does not add advertising or tracking.

## Optional permissions

Camera and photo access let you select learning examples. Microphone and speech access turn your speech into text using on-device recognition when available. You can manage these permissions in iPhone Settings. The core learning projects do not require connecting an AI account.

## Third-party services and children

Third-party downloads and AI services have their own terms, age requirements and privacy practices. PocketTrainer does not sell personal information or use advertising trackers. Use optional services only when their terms and your parent or guardian's requirements permit it.

## Contact

Luckison Du: [luckisondu@gmail.com](mailto:luckisondu@gmail.com)

[iPhone app support](SUPPORT_IOS.md)
