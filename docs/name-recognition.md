# On-device Chinese name recognition

In the Redact tool, Vision reads the image and locates its text. A bundled character-level conditional random field (CRF) predicts personal-name spans in each OCR row. It runs through Apple's Natural Language framework, including on first launch without a connection. The shipped model is a runtime asset. Training data and tools stay outside the app.

The editor uses the same model for chat messages, form fields and signatures. A field title is part of the text the model reads. It predicts name spans from the original row and filters out low-confidence predictions using the mean probability of their character tags. When a row ends in a Chinese character, the confidence calculation includes a sentence-ending punctuation mark. Each accepted span gets one reviewable cover. Original UTF-16 ranges tie each prediction to its location in the photo, including repeated mentions. Review the image before export. Usernames, uncommon names, noisy OCR and names in other scripts can be missed.

## Training

Run the following commands from the project root on a Mac with Xcode and Create ML. The script verifies each input's SHA-256. Only the training splits are used.

```sh
mkdir -p build/name-ner
curl -fL 'https://raw.githubusercontent.com/fxsjy/jieba/67fa2e36e72f69d9134b8a1037b83fbb070b9775/jieba/dict.txt' -o build/name-ner/dict.txt
curl -fL 'https://amazon-massive-nlu-dataset.s3.amazonaws.com/amazon-massive-dataset-1.1.tar.gz' -o build/name-ner/massive.tar.gz
tar -xOzf build/name-ner/massive.tar.gz '1.1/data/zh-CN.jsonl' > build/name-ner/zh-CN.jsonl
curl -fL 'https://huggingface.co/datasets/MultiCoNER/multiconer_v2/resolve/4be2d62c912977ee26ed14d2553a4fe17ca3d980/ZH-Chinese/zh_train.conll' -o build/name-ner/zh_train.conll
swift tools/train-name-model.swift build/name-ner/dict.txt build/name-ner/zh-CN.jsonl build/name-ner/zh_train.conll build/name-ner/ChinesePersonName.mlmodel
```

The model learns beginning, inside, end and outside tags. Training combines labelled entities from MultiCoNER, Chinese sentence contexts from MASSIVE and dictionary terms from jieba. Synthetic examples put people and common words in similar contexts, including requests, instructions, signatures, blank form fields and questions about when or where an event took place. Fictional forms pair names with addresses, organisation names and seal text. OCR fragments and adjacent table cells are represented in training. Name examples include annotated people and generated names with a range of surnames and given-name characters. No user photos, contacts or messages are used. Independent model training runs can produce slightly different weights. Source attributions and licenses ship in `Meward/Models/NameModelNotices.txt`.

To evaluate a new model, replace `Meward/Models/ChinesePersonName.mlmodel` with the candidate and run `RedactionTests` on an iPhone simulator. The tests check character ranges and real Vision boxes, explicit fields, split OCR observations, independent toggles and the surrounding text.
