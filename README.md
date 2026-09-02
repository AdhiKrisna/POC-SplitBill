# POC OCR receipt experiment

The POC separates document-localization preprocessing from transaction-item ROI detection.

## Hypotheses

- **H1:** Detecting and rectifying the physical receipt before document-structure recognition improves the reliability of dynamic transaction-region detection across receipts with different camera angles and layouts.
- **H2:** Improved transaction-region localization improves downstream item extraction without changing the extraction model.

## Experiment controls

Choose an extraction mode independently from document preprocessing:

| Extraction | Preprocessing |
| --- | --- |
| Vision + Regex | Original image, Document Segmentation, Segmentation + Rectification |
| Vision + ROI + Regex | Original image, Document Segmentation, Segmentation + Rectification |
| Vision + Foundation | Original image, Document Segmentation, Segmentation + Rectification |
| Vision + ROI + Foundation | Original image, Document Segmentation, Segmentation + Rectification |

`DetectDocumentSegmentationRequest` finds the physical receipt quadrilateral. The existing `VisionROIResolver` then independently finds the transaction-item region in whichever image reaches layout analysis. If document segmentation or rectification is unreliable, the pipeline falls back to the original image; if ROI confidence is low, it falls back to the full document.

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

Schema version 3 declares `document_scope=full_rectified_document` and stores
the detected ROI as optional `transaction_roi_bbox` in full-image pixel
coordinates. Python uses that bbox only for the explicit ROI ablation; the
default inference input remains the full rectified PNG.

In `05_vision_ocr_inference.ipynb`, set `OCR_JSON_PATH` to the exported JSON.
The notebook resolves the sibling PNG through `image_path` and rejects a pair
whose dimensions or SHA256 do not match.
