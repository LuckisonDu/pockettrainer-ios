# PocketTrainer

Train a small AI **on your phone, offline and free** — and watch it survive a silent GPU failure.

Idea: iOS can interrupt the GPU mid-training (a "GPU hang"). On some phones this silently corrupts the
result without any error message. PocketTrainer checks every training step on the CPU, throws away
bad GPU results and recomputes them, and saves the model atomically so a crash can be resumed.

## Build and install
Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), iOS 17+ device.
```
xcodegen generate            # makes PocketTrainer.xcodeproj from project.yml
open PocketTrainer.xcodeproj # set your Team, press Run on a real iPhone (Metal GPU needed)
```
(Our own server-to-Mac build + install script is `build_install.sh`; it is not needed for normal use.)

## Files
| File | What it does |
|---|---|
| `PocketTrainerApp.swift` | App entry; default settings; resume prompt; test-only launch flags |
| `RootView.swift` | 4 tabs (Projects / Environment / Notes / Assistant), navigation, Projects home screen |
| `EditorView.swift`, `CodeEditor.swift` | Code editor (line numbers, syntax colours), Parameters boxes synced with the code, Run, Output, loss chart |
| `FilesView.swift` | Project files tree: search, new file/folder, rename, duplicate, move, share, delete |
| `EnvironmentView.swift`, `PackCheck.swift` | Real project-pack check (manifest, versions, data SHA-256, 3-step GPU-vs-CPU test); optional download of plain-text packs |
| `SettingsView.swift` | Settings (editor, checkpoints, verify, storage, theme) |
| `NotesView.swift`, `Advice.swift`, `CoachView.swift` | Notes, learning plan, rule-based offline coach |
| `LabView.swift`, `Extras.swift` | Protection lab: interruption, crash, Compare methods, GPU limit; memory/thermal/battery |
| `Trainer.swift`, `MLCore.swift`, `GPUCore.swift`, `Checkpoint.swift` | The training core: GPU step, CPU shadow check, atomic checkpoints, resume (unchanged logic) |
| `Projects.swift`, `RunHistory.swift`, `Theme.swift`, `TeachView.swift` | Project folders, run history, look and feel, "Teach it your photos" |
| `OpenData.swift`, `DataViews.swift` | Data card on the Training tab: choose a small open dataset on Hugging Face, download it into the project's `data/` folder, train on it |
| `ResultView.swift` | Result tab: test items the model never saw go through the trained model on the phone (input → model → output, how sure, right or wrong); draw a digit for MNIST |
| `Generator.swift` | Picture generator project: a small conditional VAE (picture + class → 2 "style" numbers → picture) trained on the phone CPU with a hand-written backward pass and Adam |
| `Resources/` | Data (float16 features, 28 MB), dataset checksums, ResNet50 feature model |
| `tools/` | Resource scripts, on-device test runner (`run_matrix.sh`), screenshots (`shots.sh`), `make_verify.py` |
| `VERIFY.md`, `AI_DISCLOSURE.md` | Measured results; how AI tools were used |

The built-in trainer reads only `hidden_units`, `learning_rate`, `epochs`, `seed` from `code/model.py`; everything else in the code is shown for learning, not run as Python. Project packs are plain text and never contain runnable code.


## Training | Result tabs, open data, picture generator (added 2026-10-25)
- Every runnable project has two tabs at the top: **Training** (data, code, Run, output, loss) and **Result** (what the trained model does with test data it never saw, computed on the phone; nothing is sent anywhere).
- **Data**: the Training tab's Data card opens a short list of small open datasets on Hugging Face (MNIST, Fashion-MNIST, Iris, Fish, Breast Cancer Wisconsin, Palmer Penguins) with their live license and download count. The chosen one is downloaded into the project's `data/` folder (`source.json` records where it came from and its license) and used for training; the recipe numbers are set for about 200 steps.
- **Picture generator**: a new project template that trains a small image-generation model on the phone (conditional VAE, 2 style numbers). Its Training tab shows what it draws after every epoch; its Result tab draws new pictures of a chosen class, a 7×7 style map and encode → decode copies. It is small and blurry by design; it is not a large text-to-image model.

## Find, download and set up projects (GitHub and Hugging Face)
- **Find projects** (Projects > + > Find projects): search GitHub (python repositories) and Hugging Face (models or datasets) through their public APIs. No account or key. Results are cached on the phone.
- **Download & set up** runs the four steps of the Environment tab for real: *Analyze* (read requirements.txt / pyproject.toml / environment.yml / setup.py and the import lines), *Resolve* (compare each package with what the app really has), *Install* (download text, config and small data files only), *Test* (a 3-step GPU-vs-CPU training test when the project has a recipe).
- **Honest limits (Apple rule 2.5.2).** The app never installs Python packages and never runs downloaded code. Packages such as torch or transformers are reported as "Not available on iOS: needs native code that iOS apps cannot download". Only three things really run: a **recipe** project (built-in trainer), a **Core ML model** from Hugging Face (data run by the system's Core ML engine, compiled on the phone), and a **table dataset** (CSV/JSONL trained with the built-in trainer). Everything else can be read, edited and sent to ChatGPT for explanation.
- **Safety rules.** https only; hosts github.com, api.github.com, raw.githubusercontent.com, huggingface.co and its CDN; text extensions only; 512 KB per file, 200 files and 5 MB per import; model files are listed, not downloaded, until you tap them (50 MB, Core ML 100 MB); every file's SHA-256 and source URL are recorded; the license is shown before and after.
- **Core ML models:** download, compile on the phone, run a photo, and check the same photo on the GPU and on the CPU. "✓ Verified" means cosine similarity >= 0.999 and largest difference <= 0.02. This double-checks one run; it does not repair anything.
- **Not done:** using a downloaded Core ML feature model inside "Teach it your photos".

## Languages and ChatGPT
- Interface languages follow the system: English, Simplified Chinese, Traditional Chinese, Spanish, French (`Localizable.xcstrings`, made by `tools/make_strings.py`). Translations are machine-assisted and may contain mistakes. Code in the editor stays English.
- **Ask ChatGPT** (every page): shows the exact text it would send (page context, editable), and your question. Only when you tap *Open in ChatGPT* it copies the text and opens `https://chatgpt.com/?q=...` (first 1500 characters in the link). Nothing is sent automatically, no photos or files, no API key.
- **Speak** button (Ask ChatGPT and Add note): on-device speech recognition only (`requiresOnDeviceRecognition = true`); the button is disabled for languages the phone cannot recognise offline. Not covered by automated numbers: only the permission prompts and button states were checked.

## Data and models (all public, commercially usable)
CIFAR-10 photos (500 per class for training, 200 per class for testing) were turned into 2048 numbers each
by a pretrained ResNet50 (torchvision ImageNet weights, BSD-3). The app trains only the small
2048 → hidden → 10 classifier on top, so it takes seconds. No network access, no account, no tracking.

## Test-only launch flags
`--auto-demo=baseline|protect_on|protect_off|crash|compare|limit --tag=NAME --seed=N` runs one training without
touching the screen and writes `Documents/result.json`.
