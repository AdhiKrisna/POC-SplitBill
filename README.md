# POC OCR Receipt Experiment

Proof of Concept aplikasi iOS untuk ekstraksi receipt berbasis Apple Vision OCR dan model On-Device Core ML (LayoutLMv3).

## Features & Extraction Modes

| Pipeline | Route / Behavior |
| --- | --- |
| **Vision + LayoutLMv3 v2 Local** | Document segmentation & rectification -> Full-rectified Vision OCR -> Core ML LayoutLMv3 v2 Token Classification -> BIO Reconstruction. |
| **Vision + LayoutLMv3 Local** | LayoutLMv3 v1 token classification pada full rectified receipt. |
| **LayoutLMv3 Export** | Export full-rectified image + bounding boxes JSON untuk keperluan training / validasi di Python pipeline. |
| **Rectified + Foundation** | Perspective rectification -> Full-rectified OCR -> Apple Foundation Model parsing. |
| **Rectified + Regex** | Perspective rectification -> Full-rectified OCR -> Rule-based Regex parsing. |
| **ROI + Rectified + Regex/Foundation** | Opsional legacy mode: Transaction ROI localization -> OCR -> Regex/Foundation parsing. |

---

## Getting Started: Model Download (LayoutLMv3 Core ML)

Agar ukuran repository tetap ringan, file bobot model Core ML (`.mlpackage`) tidak di-track di dalam git. Sebelum menjalankan aplikasi pada Xcode, unduh model dari **GitHub Releases**:

### 1. Download Model Package
Unduh release asset `LayoutLMv3_v2.mlpackage.zip` (atau `LayoutLMv3_v1.mlpackage.zip`) dari halaman [Releases](https://github.com/AdhiKrisna/POC-SplitBill/releases).

### 2. Ekstrak ke Folder Project
Ekstrak file `.mlpackage` ke dalam folder `Models/LayoutLMv3/` atau langsung ke target folder `POC-OCR/`:

```bash
# Contoh penempatan file:
POC-OCR/Models/LayoutLMv3/LayoutLMv3_v2.mlpackage
# atau
POC-OCR/POC-OCR/LayoutLMv3_v2.mlpackage
```

File konfigurasi dan tokenizer (`tokenizer_v2.json`, `tokenizer_config_v2.json`, `labels_v2.json`) sudah disertakan langsung di repository project.

---

## Training & Model Export (Python Pipeline)

Training dan fine-tuning bobot model dikelola pada repository terpisah [Splitbill-Finetunning](https://github.com/AdhiKrisna/Splitbill-Finetunning.git).

Untuk mengekspor model PyTorch fine-tuned menjadi Core ML format `.mlpackage`:

```bash
python coreml_export/export_layoutlmv3_coreml.py \
  --model-dir experiments/runs/F4_cord_indonesian_wildreceipt_v2_50epoch \
  --output-dir coreml_export/out/F4_cord_indonesian_wildreceipt_v2_50epoch

python coreml_export/verify_coreml_layoutlmv3.py \
  --model-dir experiments/runs/F4_cord_indonesian_wildreceipt_v2_50epoch \
  --mlpackage coreml_export/out/F4_cord_indonesian_wildreceipt_v2_50epoch/LayoutLMv3ReceiptTokenClassifier.mlpackage
```

---

## Export Dataset dari iOS untuk Python Parity Debugging

1. Jalankan aplikasi pada simulator / device dengan mode **Vision + LayoutLMv3 v2 Local**.
2. Setelah ekstraksi selesai, tap **Export LayoutLMv3 Debug JSON**.
3. File JSON dan PNG dapat dibandingkan langsung dengan Hugging Face reference menggunakan script:
   ```bash
   python coreml_export/compare_swift_debug_with_python.py \
     --debug-json /path/to/layoutlmv3_debug_export.json \
     --model-dir experiments/runs/F4_cord_indonesian_wildreceipt_v2_50epoch
   ```
