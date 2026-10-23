# Verification on real iPhones

All numbers come from the raw `result.json` files copied off the phones (`results/<device>/<mode>_s<seed>.json`).
Script: `tools/run_matrix.sh` (launch flags `--auto-demo=<mode> --seed=N`), table made by `tools/make_verify.py`.
Accuracy = test accuracy on 2,000 photos the model never saw. Reference = the same training done fully on the CPU.

## iPhone 12 (A) (iPhone 12, A14, 4 GB)

| Mode | Launches | Accuracy per launch (%) | Mean acc (%) | Ruined (<20%) | Hang event reported by iOS | Steps fixed by protection |
|---|---|---|---|---|---|---|
| No interruption (protection on) | 6 | 86.2, 87.2, 86.4, 86.6, 87.4, 87.4 | 86.9 | 0/6 | 0/6 | 0 |
| Protection OFF + simulated interruption | 6 | 86.2, 87.2, 86.4, 86.6, 87.4, 87.4 | 86.9 | 0/6 | 6/6 | 0 |
| Protection ON + simulated interruption | 6 | 86.2, 87.2, 86.4, 86.6, 87.4, 87.4 | 86.9 | 0/6 | 6/6 | 0 |
| Simulated crash, then automatic resume | 6 | 86.2, 87.2, 86.4, 86.6, 87.4, 87.4 | 86.9 | 0/6 | 0/6 | 0 |

Crash and resume (same seed, compared with the uninterrupted run):

| Seed | Resumed from step | Final hash (resumed) | Final hash (uninterrupted) | Identical | Accuracy |
|---|---|---|---|---|---|
| 1 | 160 | 578f363477a98ca1 | 578f363477a98ca1 | yes | 86.2 |
| 2 | 160 | 28106ed256ce273d | 28106ed256ce273d | yes | 87.2 |
| 3 | 160 | a87564eb20125ad2 | a87564eb20125ad2 | yes | 86.4 |
| 4 | 160 | 760c1a682dd9d64a | 760c1a682dd9d64a | yes | 86.6 |
| 5 | 160 | dcc1fad420135e1d | dcc1fad420135e1d | yes | 87.4 |
| 6 | 160 | a3f525bd44226c31 | a3f525bd44226c31 | yes | 87.4 |

## iPhone 16 (iPhone 16, A18)

| Mode | Launches | Accuracy per launch (%) | Mean acc (%) | Ruined (<20%) | Hang event reported by iOS | Steps fixed by protection |
|---|---|---|---|---|---|---|
| No interruption (protection on) | 6 | 86.2, 87.2, 86.4, 86.6, 87.4, 87.4 | 86.9 | 0/6 | 0/6 | 0 |
| Protection OFF + simulated interruption | 6 | 10.0, 10.0, 10.0, 10.0, 10.0, 87.4 | 22.9 | 5/6 | 6/6 | 0 |
| Protection ON + simulated interruption | 6 | 86.2, 87.2, 86.4, 86.6, 87.4, 87.4 | 86.9 | 0/6 | 6/6 | 6 |
| Simulated crash, then automatic resume | 6 | 86.2, 87.2, 86.4, 86.6, 87.4, 87.4 | 86.9 | 0/6 | 0/6 | 0 |

Crash and resume (same seed, compared with the uninterrupted run):

| Seed | Resumed from step | Final hash (resumed) | Final hash (uninterrupted) | Identical | Accuracy |
|---|---|---|---|---|---|
| 1 | 160 | 6287b168264cd7ab | 6287b168264cd7ab | yes | 86.2 |
| 2 | 160 | de685e34863c2115 | de685e34863c2115 | yes | 87.2 |
| 3 | 160 | 9be5aa3a157bb75a | 9be5aa3a157bb75a | yes | 86.4 |
| 4 | 160 | 12dafa9fbe4697cf | 12dafa9fbe4697cf | yes | 86.6 |
| 5 | 160 | ef799da5cc9be21a | ef799da5cc9be21a | yes | 87.4 |
| 6 | 160 | 64771f4697c0b380 | 64771f4697c0b380 | yes | 87.4 |

## Search, import, set up, Core ML and table training (iPhone 12 (A), raw files in `results/iphone12_a/`)

- **Search** `search_github_micrograd.json`: {"count": 20, "first": ["tinygrad/tinygrad [MIT] stars=33779 downloads=-1", "mlecauchois/micrograd-cuda [MIT] stars=252 downloads=-1", "automata/mojograd [no license] stars=79 downloads=-1", "kibotu/karpathy-microgpt [no license] stars=58 downloads=-1", "noway/yagrad [MIT] stars=26 downloads=-1"], "q": "micrograd", "seconds": 0.9232580661773682, "source": "github"}
- **Search** `search_hf_mnist.json`: {"count": 20, "first": ["tanganke/clip-vit-base-patch32_mnist [no license] stars=-1 downloads=19256", "tanganke/clip-vit-large-patch14_mnist [no license] stars=-1 downloads=13227", "tanganke/clip-vit-base-patch16_mnist [no license] stars=-1 downloads=11248", "asnelt/mnistvit-transformers [mit] stars=-1 downloads=2953", "gaurangdave/mnist_cnn [no license] stars=-1 downloads=2661"], "q": "mnist", "seconds": 0.17336201667785645, "source": "hf"}
- **Import** `import_1.json`: {"bytes": 350649, "files": 23, "license": "MIT", "licenseFetched": true, "mapCandidates": ["learning_rate=1e-4→learning_rate", "learning_rate=3e-5→learning_rate", "learning_rate=1e-3→learning_rate", "learning_rate=6e-4→learning_rate"], "project": "nanoGPT", "recipeFound": false, "seconds": 2.6127519607543945, "skipped": [".gitattributes (hidden)", "assets/gpt2_124M_loss.png (file type not allowed)", "assets/nanogpt.jpg (file type not allowed)"], "url": "https://github.com/karpathy/nanoGPT"}
- **Import** `import_2.json`: {"error": "This is too big to import (210 files, 0.9 MB; limits: 200 files, 5 MB). Pick a sub-folder.", "seconds": 0.5313880443572998, "url": "https://github.com/pytorch/examples"}
- **Import** `import_3.json`: {"bytes": 7082, "files": 4, "license": "BSD-3-Clause", "licenseFetched": true, "mapCandidates": [], "project": "examples-mnist", "recipeFound": false, "seconds": 0.7899309396743774, "skipped": [], "url": "https://github.com/pytorch/examples/tree/main/mnist"}
- **Import** `import_nanoGPT.json`: {"bytes": 350649, "files": 23, "license": "MIT", "licenseFetched": true, "mapCandidates": ["learning_rate=1e-4→learning_rate", "learning_rate=3e-5→learning_rate", "learning_rate=1e-3→learning_rate", "learning_rate=6e-4→learning_rate"], "project": "nanoGPT", "recipeFound": false, "seconds": 2.6127519607543945, "skipped": [".gitattributes (hidden)", "assets/gpt2_124M_loss.png (file type not allowed)", "assets/nanogpt.jpg (file type not allowed)"], "url": "https://github.com/karpathy/nanoGPT"}
- **Download & set up** `setup_https___github.com_karpathy_micrograd.json`: {"bytes": 71124, "coremlFound": false, "files": 10, "license": "MIT", "packages": ["setuptools  → Not available on iOS", "torch  → Not available on iOS"], "passed": true, "project": "micrograd 2", "recipe": "none", "report": "Missing: setuptools, torch", "seconds": 2.714972972869873, "skipped": ["gout.svg (file type not allowed)", "moon_mlp.png (file type not allowed)", "puppy.jpg (file type not allowed)"], "status": "Missing: setuptools, torch", "tablesFound": false, "url": "https://github.com/karpathy/micrograd", "weightsListed": []}
- **Download & set up** `setup_https___huggingface.co_sentence-transformers_all-MiniLM-L6-v2.json`: {"bytes": 762460, "coremlFound": false, "files": 12, "license": "apache-2.0", "packages": ["torch  → Not available on iOS", "torch-xla  → Not available on iOS", "tqdm  → Not available on iOS", "transformers  → Not available on iOS"], "passed": true, "project": "all-MiniLM-L6-v2", "recipe": "none", "report": "Missing: torch, torch-xla, tqdm, transformers", "seconds": 2.424247980117798, "skipped": [".gitattributes (hidden)", "openvino/openvino_model.xml (file type not allowed)", "openvino/openvino_model_qint8_quantized.xml (file type not allowed)"], "status": "Missing: torch, torch-xla, tqdm, transformers", "tablesFound": false, "url": "https://huggingface.co/sentence-transformers/all-MiniLM-L
- **Core ML** `coreml_apple_coreml-resnet-50.json`: {"candidates": ["Resnet50Int8LUT.mlmodel 25677037", "Resnet50FP16.mlmodel 51313342", "Resnet50Headless.mlmodel 94367931", "Resnet50.mlmodel 102586812"], "cosine": 0.9999979283340577, "cpuSeconds": 0.060798048973083496, "cpuTop5": ["web site, website, internet site, site 0.3545", "ping-pong ball 0.2883", "envelope 0.2166", "golf ball 0.0108", "guillotine 0.0077"], "description": ["in  image: image 224×224", "out classLabel: text", "out classLabelProbs: dictionary (label → probability)"], "downloadBytes": 25677037, "gpuSeconds": 0.806920051574707, "maxDiff": 0.0008629858493804932, "model": "Resnet50Int8LUT.mlmodel", "prepareSeconds": 1.7274199724197388, "project": "coreml-resnet-50 3", "repo":
- **Core ML** `coreml_apple_coreml-resnet-50_Resnet50Headless.json`: {"candidates": ["Resnet50Int8LUT.mlmodel 25677037", "Resnet50FP16.mlmodel 51313342", "Resnet50Headless.mlmodel 94367931", "Resnet50.mlmodel 102586812"], "cosine": 0.9999987545543167, "cpuSeconds": 0.03314507007598877, "cpuTop5": ["#249 12.2796", "#395 10.6689", "#981 6.8152", "#836 6.7957", "#2008 5.5825"], "description": ["in  image: image 224×224", "out averagePoolingOutput: array [2048, 1, 1]"], "downloadBytes": 94367931, "gpuSeconds": 1.0760310888290405, "maxDiff": 0.010573863983154297, "model": "Resnet50Headless.mlmodel", "prepareSeconds": 3.3876149654388428, "project": "coreml-resnet-50 4", "repo": "apple/coreml-resnet-50", "seconds": 10.109219074249268, "teachSelfTestWithThisModel": {
- **Table dataset** `dataset_scikit-learn_iris.json`: {"accuracy": 0.9666666666666667, "classes": ["Iris-setosa", "Iris-versicolor", "Iris-virginica"], "cpuReferenceAccuracy": 0.9666666666666667, "features": ["SepalLengthCm", "SepalWidthCm", "PetalLengthCm", "PetalWidthCm"], "file": "Iris.csv", "flaggedSteps": 0, "label": "Species", "project": "iris 2", "repo": "scikit-learn/iris", "rows": 150, "seconds": 2.9529320001602173, "steps": 200, "trainSeconds": 0.733909010887146}

## What was verified on which phone

| Feature | iPhone 12 (A) (iPhone 12) | iPhone 16 (iPhone 16) | Notes |
|---|---|---|---|
| Training core regression, 24 launches (baseline / protection off / on / crash) | final build: all 24 final weight hashes identical to the first v2 results | v2 build 2a3331d: protection off + interruption ruined 5/6 launches (10%), protection on repaired 6/6, crash resume hashes identical 6/6 | iPhone 16 numbers differ from iPhone 12 (different GPU) |
| Measure my phone's limit | 0.254 s | 0.506 s | |
| Compare methods | all three methods equal (interruption does not corrupt on this phone) | rows saved in `results/iphone16/compare_x16.json`: unprotected run ruined | |
| Search GitHub / Hugging Face, Download & set up, dependency analysis | yes (`search_*`, `setup_*`) | not run (phone returned) | GitHub import of micrograd also worked on iPhone 16 with commit 04a91ba |
| Core ML download, on-device compile, run, GPU-vs-CPU check | yes: Resnet50Int8LUT 25.7 MB and Resnet50Headless 94.4 MB, verified (cosine >= 0.99999) | no | uses a built-in sample picture; choosing a photo from the library was not automated |
| Core ML model as feature extractor in Teach it your photos | yes: self-test 15/15 with the downloaded 2048-number model | no | |
| Table dataset (Iris, CSV) trained on the phone | yes: 96.7% test accuracy, same as the CPU reference | no | |
| Five interface languages | yes (screenshots in `v2/lang/`, no cut-off text seen) | no | machine-assisted translations |
| Ask ChatGPT sheet | sheet and prompt shown (screenshot); the hand-off to chatgpt.com was not automated | no | nothing is sent automatically |
| Speak (on-device speech recognition) | button shown only; permission prompt, recognition and noise handling were **not** tested | no | no automated numbers exist for speech |
| App icon and in-app logo | yes (home screen and in-app logo) | no | |

