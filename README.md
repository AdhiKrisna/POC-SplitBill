# POC OCR receipt experiment

The POC separates document-localization preprocessing from transaction-item ROI detection.

## Hypotheses

- **H1:** Detecting and rectifying the physical receipt before document-structure recognition improves the reliability of dynamic transaction-region detection across receipts with different camera angles and layouts.
- **H2:** Improved transaction-region localization improves downstream item extraction without changing the extraction model.

## Experiment controls

Choose one complete experiment pipeline:

| Pipeline | Route |
| --- | --- |
| Rectified + Regex | document segmentation, perspective rectification, full-rectified OCR, regex parsing |
| ROI + Rectified + Regex | document segmentation, perspective rectification, transaction ROI detection, transaction ROI OCR, regex parsing |
| Rectified + Foundation | document segmentation, perspective rectification, full-rectified OCR, Foundation Model parsing |
| ROI + Rectified + Foundation | document segmentation, perspective rectification, transaction ROI detection, transaction ROI OCR, Foundation Model parsing |
| FastVLM | document segmentation, perspective rectification, full-rectified OCR, experimental on-device VLM JSON extraction |
| LayoutLMv3 Export | document segmentation, perspective rectification, full-rectified OCR, export full rectified image plus OCR words and bounding boxes |
| Vision + LayoutLMv3 Local | document segmentation, perspective rectification, full-rectified Vision OCR, local Core ML token classification, BIO decoding, conservative line-item grouping |

`DetectDocumentSegmentationRequest` finds the physical receipt quadrilateral, shown as the blue document-boundary overlay. Rectification then produces the complete frontal receipt. `VisionROIResolver` remains an optional legacy-only transaction-item stage for the two ROI extraction modes; it is not used to prepare LayoutLMv3 input.

## Export to LayoutLMv3

After extraction, open the receipt result and tap **Export LayoutLMv3 PNG + JSON**.
Share or save both files together. The PNG is the exact upright image whose
coordinate space produced the Vision observations. LayoutLMv3 export always
uses the full successfully rectified document, even when the native extraction
mode uses ROI. If rectification fell back to the original image, export stops
with an error instead of labelling an unrectified or ROI image as P0-valid.

The JSON contains word-level text and pixel boxes with a top-left origin,
image dimensions, the relative PNG filename, and its SHA256 digest. If Vision
cannot derive a word box for a line, that line is retained as a documented
fallback instead of being silently dropped.

Schema version 3 declares `document_scope=full_rectified_document`. The bundle
contains no transaction ROI metadata: LayoutLMv3 receives the full rectified
PNG plus full-document OCR words and boxes. Legacy ROI experiments remain
separate from this export contract.

In `05_vision_ocr_inference.ipynb`, set `OCR_JSON_PATH` to the exported JSON.
The notebook resolves the sibling PNG through `image_path` and rejects a pair
whose dimensions or SHA256 do not match.

## Local Core ML inference

Create the ML Program package from the LayoutLMv3 repository root:

```bash
python coreml_export/export_layoutlmv3_coreml.py \
  --model-dir experiments/runs/F4_cord_indonesian_wildreceipt_v2_50epoch \
  --output-dir coreml_export/out/F4_cord_indonesian_wildreceipt_v2_50epoch

python coreml_export/verify_coreml_layoutlmv3.py \
  --model-dir experiments/runs/F4_cord_indonesian_wildreceipt_v2_50epoch \
  --mlpackage coreml_export/out/F4_cord_indonesian_wildreceipt_v2_50epoch/LayoutLMv3ReceiptTokenClassifier.mlpackage
```

Add these generated files to the POC-OCR target:

- `LayoutLMv3_v2.mlpackage`
- `tokenizer_v2.json`
- `tokenizer_config_v2.json`
- `labels_v2.json`

The expected model features are `input_ids` `[1,512]`, `attention_mask`
`[1,512]`, `bbox` `[1,512,4]`, `pixel_values` `[1,3,224,224]`, and output
`logits` `[1,512,17]` for the current F4 V2 model. Select **Vision + LayoutLMv3 Local** to run the package.
Missing resources, invalid tokenizer/labels, empty OCR, tensor-shape problems,
unknown labels, and Core ML prediction failures are surfaced as extraction
errors rather than falling back to Regex.

This mode differs from Vision + Regex because the model labels each OCR token
using text, 2D layout, and receipt pixels. It differs from Vision + Foundation
because it does not generate a semantic response or JSON. It is still OCR-based:
Vision supplies words and bounding boxes before LayoutLMv3 runs. LayoutLMv3 is a
token classifier, so converting BIO labels into receipt items remains a separate
post-processing stage.

Prototype limitations: one fixed 512-token window, a locally implemented
RoBERTa byte-level BPE adapter that still needs corpus-wide parity testing, and
conservative row grouping. Receipts beyond the token window are truncated.

For device parity, run **Vision + LayoutLMv3 Local**, then tap **Export
LayoutLMv3 Debug JSON**. The share sheet includes
`layoutlmv3_debug_export.json` and the matching full-rectified
`layoutlmv3_debug_receipt.png`. The JSON records Vision and normalized word
boxes, ordered OCR words, every token ID and word ID, special/padding tokens,
attention mask, token boxes, Core ML logits, predicted label IDs/confidences,
word-level first-subword aggregation, BIO entities, reconstruction status, and
the exact NCHW Float32 RGB tensor supplied to Core ML.

Compare it in the LayoutLMv3 Python repository:

```bash
python coreml_export/compare_swift_debug_with_python.py \
  --debug-json /path/to/layoutlmv3_debug_export.json \
  --model-dir experiments/runs/F1_2_cord_indonesian_v1_110epoch
```

The on-device debug view is word-oriented: each Vision OCR word is followed by
its subwords, token IDs, LayoutLM box, predicted BIO label, and confidence.
Grouping remains unchanged until this preprocessing and argmax trace matches
the Hugging Face reference.

## FastVLM Experiment

Select **FastVLM** to run the experimental receipt-structuring path. This route
uses the full rectified receipt image and the raw Vision OCR text as grounding
context. It does not use the legacy transaction ROI.

The app is prepared for Apple's official `ml-fastvlm` Swift/MLX loading pattern,
but the runtime dependency is intentionally isolated in
`POC-OCR/FastVLM/FastVLMReceiptExtractor.swift` until the model package policy is
final. The first target model is Apple's Apple Silicon-compatible
`fastvlm_0.5b_stage3`, matching the smallest Stage 3 option published for
device feasibility work.

Do not commit model files. Place local experiment files under:

```text
Models/FastVLM/fastvlm_0.5b_stage3/
```

`fastvlm_0.5b_stage3` is the canonical folder name for this POC. Remove or
ignore duplicate export folders such as `llava-fastvithd_0.5b_stage3`; the app
does not search them.

The app checks these locations in order and logs each checked path:

- app bundle `Models/FastVLM/fastvlm_0.5b_stage3`
- app bundle root `fastvlm_0.5b_stage3`
- Application Support `Models/FastVLM/fastvlm_0.5b_stage3`

The app will show a clear warning if the FastVLM model is not installed:
`FastVLM model is not installed. Please add fastvlm_0.5b_stage3 model files.`
If the model is present but the Swift runtime has not been wired yet, it shows:
`FastVLM model files found, but FastVLM/MLX runtime is not integrated.`
