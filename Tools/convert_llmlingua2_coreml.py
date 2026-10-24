#!/usr/bin/env python3
"""
Build the Core ML package that TypstEdit downloads for its optional
"LLMLingua-2" chat-compression method.

What it does
------------
1. Loads Microsoft's small LLMLingua-2 token classifier
   (bert-base-multilingual-cased variant) from the Hugging Face Hub.
2. Traces and converts it to Core ML with a FIXED 512-token input window
   and stable tensor names — TypstEdit relies on these exact names:
       inputs:  input_ids, attention_mask, token_type_ids  (Int32, [1, 512])
       output:  logits                                     (Float, [1, 512, 2])
3. Saves `LLMLingua2.mlpackage` (float16) alongside the tokenizer's
   `vocab.txt`, and zips both into `LLMLingua2-CoreML.zip`, ready to publish.

Publishing
----------
Upload the zip as a release asset on the TypstEdit repository under a
dedicated model tag, so that
    https://github.com/tmagri/TypstEdit/releases/download/llmlingua2-coreml-v1/LLMLingua2-CoreML.zip
resolves to it (see LLMLingua2Manager.modelArchiveURL in the app), and paste
the zip's SHA-256 into LLMLingua2Manager.expectedArchiveSHA256. When the
model changes, publish a new tag (llmlingua2-coreml-v2, …) and update both
the URL tag and the checksum.

Usage
-----
    pip install torch transformers coremltools
    python3 Tools/convert_llmlingua2_coreml.py [--out output_dir]
"""

import argparse
import shutil
import subprocess
import zipfile
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from transformers import AutoModelForTokenClassification, AutoTokenizer

MODEL_ID = "microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank"
SEQUENCE_LENGTH = 512
PACKAGE_NAME = "LLMLingua2"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/llmlingua2-coreml"))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    print(f"Loading {MODEL_ID} …")
    model = AutoModelForTokenClassification.from_pretrained(MODEL_ID)
    model.eval()
    # HF models return an output *dict* by default, which torch.jit.trace
    # refuses to handle; tuples trace cleanly and ct.convert picks the
    # logits tensor up as the single output.
    model.config.return_dict = False
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)

    dummy = {
        "input_ids": torch.ones(1, SEQUENCE_LENGTH, dtype=torch.long),
        "attention_mask": torch.ones(1, SEQUENCE_LENGTH, dtype=torch.long),
        "token_type_ids": torch.zeros(1, SEQUENCE_LENGTH, dtype=torch.long),
    }

    print("Tracing …")
    with torch.no_grad():
        traced = torch.jit.trace(model, (dummy["input_ids"], dummy["attention_mask"], dummy["token_type_ids"]))

    print("Converting to Core ML (float16) …")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQUENCE_LENGTH), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQUENCE_LENGTH), dtype=np.int32),
            ct.TensorType(name="token_type_ids", shape=(1, SEQUENCE_LENGTH), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits")],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
    )

    package_path = args.out / f"{PACKAGE_NAME}.mlpackage"
    print(f"Saving {package_path} …")
    mlmodel.save(str(package_path))

    vocab_path = args.out / "vocab.txt"
    tokenizer.save_vocabulary(str(args.out))
    print(f"Saved {vocab_path}")

    # A quick smoke check against PyTorch on the dummy input keeps honest
    # conversions honest — numbers should agree to float16 tolerance.
    print("Checking Core ML output against PyTorch …")
    with torch.no_grad():
        expected = model(**dummy)[0].numpy()
    loaded = ct.models.MLModel(str(package_path))
    actual = loaded.predict({
        "input_ids": dummy["input_ids"].numpy().astype("int32"),
        "attention_mask": dummy["attention_mask"].numpy().astype("int32"),
        "token_type_ids": dummy["token_type_ids"].numpy().astype("int32"),
    })["logits"]
    max_error = abs(expected - actual).max()
    print(f"  max abs difference: {max_error:.4f}")
    if max_error > 0.5:
        raise SystemExit("Core ML output diverges from PyTorch — do not publish this build.")

    zip_path = args.out / "LLMLingua2-CoreML.zip"
    print(f"Zipping {zip_path} …")

    # The archive carries its own license: the model is Apache-2.0, and a
    # redistributed derivative must ship the license text and state the
    # modification (see THIRD_PARTY_NOTICES.md in the repository).
    license_src = Path(__file__).resolve().parent.parent / "THIRD_PARTY_NOTICES.md"
    notice_text = (
        "LLMLingua2-CoreML\n"
        "==================\n\n"
        "Core ML conversion of microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank\n"
        "(base model: google-bert/bert-base-multilingual-cased).\n"
        "Copyright 2024 Microsoft Corporation — Apache License 2.0.\n\n"
        "Modifications: format conversion to Apple Core ML (float16, fixed\n"
        "512-token input window) by the TypstEdit project; weights unchanged.\n"
        "License text: see LICENSE in this archive.\n"
    )
    license_dir = args.out / "licenses"
    license_dir.mkdir(exist_ok=True)
    if license_src.exists():
        (license_dir / "LICENSE").write_text(license_src.read_text())
    else:
        print("  warning: THIRD_PARTY_NOTICES.md not found next to this script")
    (license_dir / "NOTICE").write_text(notice_text)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(args.out.rglob("*")):
            if path == zip_path or path == args.out:
                continue
            archive.write(path, path.relative_to(args.out))

    sha = subprocess.run(["shasum", "-a", "256", str(zip_path)], capture_output=True, text=True).stdout.split()[0]
    print("\nDone.")
    print(f"  archive: {zip_path}")
    print(f"  sha256:  {sha}   <- paste into LLMLingua2Manager.expectedArchiveSHA256")
    print("Publish this zip as a GitHub release asset, then update modelArchiveURL if needed.")


if __name__ == "__main__":
    main()
