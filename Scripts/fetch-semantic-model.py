#!/usr/bin/env python3
"""Explicit developer-only download of pinned original MobileCLIP Core ML assets.
No Python package installation. The native library/CLI never accesses the network.
Models/tokenizer data are separate licensed assets; see MODEL_CARD.md and LICENSE_weights_data.
"""
import argparse, concurrent.futures, hashlib, json, os, pathlib, tempfile, urllib.request
REVISION = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"
TOKENIZER_REVISION = "48faa0fea4b08d74188b3841771aca6ff2c92852"
EXPECTED = {
  "LICENSE_weights_data": "a94a7a9c59509751580a31fa1ab3b418a97b01304549d382b8b96ca8fa85a179",
  "MODEL_CARD.md": "deca0d6bae82205985920c2de94ad1c1198da5944c7a208d9ca67b6600ae442e",
  "clip-merges.txt": "7e0847f6fced8bd28a736dcaeab20e64ac19010771700197ba479a0a8e517d4f",
  "clip-vocab.json": "7aeb221a2a93047170070379743b49204c13d6993d9947323cd94b75c1f657ba",
  "mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/model.mlmodel": "2c1afa132c41c6535817cc67894bd7484bc2cbd084ed5e2f12b24f611af17591",
  "mobileclip_s0_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "87d8f63997bbd2f38ba7defeaaa2c571928bdece56aa9629542198b3ce906ed6",
  "mobileclip_s0_image.mlpackage/Manifest.json": "fe07dde983dae92c1799132816ce55f9ff8487f2681b530abf7222025aa27fa4",
  "mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/model.mlmodel": "81eba836ff4dbc8ae021d70006288b533ba7eed3c2973d245b0d5ea047305bfd",
  "mobileclip_s0_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "34723e51445b2630106e94e1fdbebed80e7676b404fb839f4eb9bec97bdcad68",
  "mobileclip_s0_text.mlpackage/Manifest.json": "a7cb0864a627468a953afd107262097ad74a0fcf82e49df7e00b9c86385bb7db",
  "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel": "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b",
  "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00",
  "mobileclip_s2_image.mlpackage/Manifest.json": "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6",
  "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/model.mlmodel": "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80",
  "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce",
  "mobileclip_s2_text.mlpackage/Manifest.json": "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0"
}
EXTRA = {
  "MODEL_CARD.md": "https://huggingface.co/apple/coreml-mobileclip/resolve/3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947/README.md",
  "LICENSE_weights_data": "https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/341ef058802f0e4e5ab13c02f0cb32a3a94e367b/LICENSE_weights_data"
}

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=["s0", "s2", "both"], default="s2")
    parser.add_argument("--destination", type=pathlib.Path, default=pathlib.Path(".work/semantic/models"))
    args = parser.parse_args()
    root = args.destination
    root.mkdir(parents=True, exist_ok=True)
    def wanted(name):
        return not name.startswith("mobileclip_") or args.variant == "both" or name.startswith("mobileclip_" + args.variant + "_")
    def fetch(name):
        target = root / name
        if target.exists():
            if digest(target) != EXPECTED[name]:
                raise ValueError("Existing asset has a different hash; preserved: " + str(target))
            return
        if name in EXTRA:
            url = EXTRA[name]
        elif name.startswith("clip-"):
            url = "https://raw.githubusercontent.com/apple-aiml-research/ml-mobileclip/" + TOKENIZER_REVISION + "/ios_app/MobileCLIPExplore/Resources/" + name
        else:
            url = "https://huggingface.co/apple/coreml-mobileclip/resolve/" + REVISION + "/" + name + "?download=true"
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".pxl-download-", delete=False) as out:
                temporary = pathlib.Path(out.name)
                with urllib.request.urlopen(url, timeout=120) as response:
                    while chunk := response.read(1024 * 1024):
                        out.write(chunk)
            if digest(temporary) != EXPECTED[name]:
                raise ValueError("Downloaded asset hash mismatch: " + name)
            try:
                os.link(temporary, target)  # no overwrite, including concurrent setup
            except FileExistsError:
                if digest(target) != EXPECTED[name]:
                    raise
            print("Verified " + name, flush=True)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(fetch, [name for name in EXPECTED if wanted(name)]))
    files = {name: sha for name, sha in EXPECTED.items() if (root / name).is_file() and digest(root / name) == sha}
    manifest = {"schemaVersion": 1, "repository": "apple/coreml-mobileclip", "revision": REVISION,
                "tokenizerRevision": TOKENIZER_REVISION, "files": files}
    # Only this generated manifest is replaced; existing model assets are preserved.
    path = root / "download-manifest.json"
    with tempfile.NamedTemporaryFile(dir=root, prefix=".pxl-manifest-", mode="w", delete=False) as f:
        json.dump(manifest, f, indent=2)
        temporary = pathlib.Path(f.name)
    temporary.replace(path)
    print("Verified model cache: " + str(root.resolve()))

if __name__ == "__main__":
    main()
