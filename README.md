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
