# AI use disclosure — PocketTrainer

Prepared 2026-10-20 from the actual development log. Edit this file so it matches what the student did herself/himself.

## Tools
Source code was written with **Claude Code (Claude Sonnet 5.5, Anthropic)** from a written specification supplied by the team; the 2026-10-25 additions (open data, Result tab, picture generator) were written with Claude Code (Claude Opus 5.5).
The AI wrote the Swift code, build scripts, test scripts and README; the team defined the idea, the behaviour,
the experiments, and ran/checked the results on real iPhones. The AI did not run anything outside the team's own machines.

## File by file
| File | Origin |
|---|---|
| `MLCore.swift` — CPU network (`CPUNet.step`, `accuracy`), LCG random numbers, `updateMismatch` | **Reused research logic** from our earlier experiment app (`TrainHead.swift`: CPU back-propagation, seeded init and shuffle, 1−cos update check); re-organised, renamed, commented in a new file by AI |
| `GPUCore.swift` — `GPUNet` (MPSGraph training step) | **Reused research logic** (same MPSGraph graph and auto-gradient as `TrainHead.swift`), restructured by AI |
| `GPUCore.swift` — `Interruption` (GPU hang simulator) | **Reused** Metal "hang kernel" from our research code (`SegTest.makeHangKernel`), wrapped by AI |
| `Checkpoint.swift` — atomic save, FNV checksum, session file | Atomic save/checksum logic **reused** from `TrainHead.swift`; session/`Config` struct **new** |
| `Trainer.swift` — training loop, shadow check + retry + CPU fallback, crash/resume, result file | Loop logic **reused in idea** from `TrainHead.swift`; the app state machine, banner logic, auto-resume, `result.json` are **new** (AI) |
| `Extras.swift` — Compare methods, Measure my phone's limit, memory/thermal/battery | **New** (AI). The limit meter follows the idea of our research `watchdogCal` (Metal loop kernel, growing loop counts); the "Checkpoint-only" baseline follows our earlier experiment arm |
| v2 interface: `RootView`, `EditorView`, `CodeEditor`, `FilesView`, `EnvironmentView`, `PackCheck`, `SettingsView`, `NotesView`, `Advice`, `CoachView`, `LabView`, `Projects`, `RunHistory`, `Theme` | **New** (AI), built from a reference design image supplied by the team (the design's placeholder content was not copied). Rule-based coach/takeaways are plain if-rules, no AI model inside the app. The training core they call is the reused research logic above |
| `GitHubImport`, `SearchView`, `DepScan`, `CoreMLTools`, `CoreMLView`, `TabularTools`, `ProjectTools`, `RecipeMap`, `AutoDemo`, `License` | **New** (AI): search, safe download, dependency analysis, Core ML download/compile/run with GPU-vs-CPU check, table training |
| `AskChatGPT`, `Speech`, `L10n`, `Localizable.xcstrings` | **New** (AI). Translations (zh-Hans, zh-Hant via OpenCC, es, fr) were produced by AI and are machine-assisted |
| `PocketTrainerApp.swift` | **New** (AI): SwiftUI interface, Swift Charts curve, test-only launch flags, UI screenshot renderer |
| `OnboardingView.swift` (first-run 3-step guide), `ExportView.swift` (Export card), `CoreMLExport.swift` (hand-written Core ML / safetensors writer, verification against the CPU result) | **New** (AI), 2026-10-21/22 |
| `OpenData.swift`, `DataViews.swift` (Data card: pick a small open dataset on Hugging Face, download it into the project's `data/` folder and train on it), `ResultView.swift` (Result tab: test items go through the trained model on the phone — input → model → output; draw-a-digit), `Generator.swift` (Picture generator: a small conditional VAE with hand-written forward/backward pass and Adam, trained on the phone's CPU) | **New** (AI), 2026-10-25 |
| `TeachView.swift` (bonus) | **New** (AI): photo picking, Core ML feature extraction, tiny 3-class classifier, self-test |
| `tools/*.sh`, `build_install.sh`, `project.yml` | Build/install flow adapted from our earlier app's script; test runner **new** (AI) |
| `tools/make_resources.py`, `tools/export_features_model.py` | **New** (AI) |
| `Resources/*.f16, *.u8` | Data made by our earlier script `make_head_data.py` (CIFAR-10 → ResNet50 features), converted to float16 |
| `Resources/cifar_thumbs.u8` | 80 CIFAR-10 test images (8 per class, 32×32) shown on the Result tab; an AI-written check confirmed each one is the image behind the bundled test features (ResNet50 feature match) |
| `Resources/ResNet50Features.mlpackage` | Converted by AI-written script from torchvision ResNet50 ImageNet weights |

## Third-party material (all public, commercially usable)
- CIFAR-10 dataset (Krizhevsky, 2009). 
- torchvision ResNet50 ImageNet weights (BSD-3-Clause).
- Open datasets the user can choose to download from Hugging Face (not bundled): MNIST (MIT), Fashion-MNIST (MIT), Iris (CC0), Fish (CC-BY-4.0), Breast Cancer Wisconsin (CC-BY-SA-4.0), Palmer Penguins (CC0).
- Apple frameworks only: SwiftUI, Swift Charts, Metal, MPSGraph, Accelerate, Core ML, PhotosUI.
- The only network use is when the user searches or downloads from GitHub / Hugging Face (https, allow-listed hosts; files are shown, never executed). No other libraries. No personal photos or faces are included in the app or its data.

## Not in this app
Our own research models/adapters, video-generation models, and any photos of people.

## What the team (not the AI) did
> **STUDENT: before submitting, check every sentence below and edit it so it is exactly true.** Add the specific functions or screens you wrote or changed yourself (with dates), because the contest requires a significant personal contribution and AI use that is not the whole development.

Problem choice and the finding that GPU interruptions can silently ruin training on some iPhones; the experimental design; running
all tests on the real phones; deciding what the results mean. The AI's tests numbers are in `VERIFY.md` with raw files in `results/`.
