#!/usr/bin/env python3
"""Download and verify the on-device models bundled into AutoTranscribe.

Ported from .github/workflows/ios-autotranscribe.yml steps
"Bundle ASR models into app resources" and
"Bundle on-device AI models ..." so the same resource layout can be recreated
on the machine that runs xtool. No runtime model download exists in the app.

Usage (from anywhere):
    python3 xtool/prepare_models.py                 # download everything
    python3 xtool/prepare_models.py --group whisper
    python3 xtool/prepare_models.py --group ai
    python3 xtool/prepare_models.py --group verify  # only check files

Total download is roughly 1.2 GB. Re-running skips files that are complete.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODELS = ROOT / "Examples/AutoTranscribe/AutoTranscribe/Models"
AI = MODELS / "ai-models"

HF = "https://huggingface.co"
MIRROR = "https://hf-mirror.com"
WHISPER_REPO = "argmaxinc/whisperkit-coreml"

WHISPER_FOLDERS = {
    "whisper-base": "openai_whisper-base",
    "whisper-turbo": "openai_whisper-large-v3-v20240930_turbo",
}

SV = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
SP = "csukuangfj/speaker-embedding-models"
EG = "ggml-org/embeddinggemma-300M-GGUF"

# relative path under ai-models -> (minimum bytes, candidate URLs)
AI_FILES = {
    "sense-voice/model.int8.onnx": (
        200_000_000,
        [f"{HF}/{SV}/resolve/main/model.int8.onnx",
         f"{MIRROR}/{SV}/resolve/main/model.int8.onnx"],
    ),
    "sense-voice/tokens.txt": (
        100_000,
        [f"{HF}/{SV}/resolve/main/tokens.txt",
         f"{MIRROR}/{SV}/resolve/main/tokens.txt"],
    ),
    "silero_vad.int8.onnx": (
        100_000,
        ["https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.int8.onnx",
         "https://ghproxy.net/https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.int8.onnx",
         f"{MIRROR}/csukuangfj/vad/resolve/main/silero_vad.onnx"],
    ),
    "campplus/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx": (
        20_000_000,
        [f"{HF}/{SP}/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
         f"{MIRROR}/{SP}/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"],
    ),
    "embeddinggemma-300M-Q8_0.gguf": (
        300_000_000,
        [f"{HF}/{EG}/resolve/main/embeddinggemma-300M-Q8_0.gguf",
         f"{MIRROR}/{EG}/resolve/main/embeddinggemma-300M-Q8_0.gguf"],
    ),
}


def hf_urls(repo: str, path: str):
    quoted = urllib.parse.quote(path, safe="/")
    return [f"{HF}/{repo}/resolve/main/{quoted}",
            f"{MIRROR}/{repo}/resolve/main/{quoted}"]


def fetch(urls, dst: pathlib.Path, minimum: int) -> bool:
    if dst.exists() and dst.stat().st_size >= minimum:
        print(f"  skip (complete) {dst.relative_to(MODELS)}")
        return True
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(dst) + ".part")
    for url in urls:
        print(f"  GET {url}")
        proc = subprocess.run(
            ["curl", "-fL", "--retry", "2", "--retry-all-errors",
             "--connect-timeout", "20", "--max-time", "900", "-o", str(tmp), url],
            check=False,
        )
        if proc.returncode == 0 and tmp.exists() and tmp.stat().st_size >= minimum:
            tmp.replace(dst)
            print(f"  OK {dst.relative_to(MODELS)} ({dst.stat().st_size} bytes)")
            return True
        print(f"  failed: {url}")
    tmp.unlink(missing_ok=True)
    return False


def hf_list_files(repo: str, subdir: str):
    quoted = urllib.parse.quote(subdir, safe="/")
    for base in (HF, MIRROR):
        url = f"{base}/api/models/{repo}/tree/main/{quoted}?recursive=true&expand=true"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "AutoTranscribe-xtool/1.0"})
            with urllib.request.urlopen(req, timeout=60) as response:
                data = json.load(response)
            files = [x["path"] for x in data if x.get("type") == "file"]
            if files:
                return files
        except Exception as exc:  # noqa: BLE001 - network fallbacks are intentional
            print(f"  tree API unavailable ({base}): {exc}")
    return None


def flatten_snapshot(dst: pathlib.Path, subdir: str) -> None:
    """Mirror the CI behaviour: lift <subdir>/* to the model folder root."""
    src = dst / subdir
    if not src.is_dir():
        return
    for child in src.iterdir():
        target = dst / child.name
        if target.exists():
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
        shutil.move(str(child), str(target))
    src.rmdir()


def download_whisper() -> bool:
    ok = True
    for folder, subdir in WHISPER_FOLDERS.items():
        dst = MODELS / folder
        dst.mkdir(parents=True, exist_ok=True)
        print(f"=== WhisperKit {folder} ({subdir}) ===")
        files = hf_list_files(WHISPER_REPO, subdir)
        if files is None:
            print("  falling back to huggingface_hub.snapshot_download")
            try:
                from huggingface_hub import snapshot_download  # type: ignore
                snapshot_download(repo_id=WHISPER_REPO, local_dir=str(dst),
                                  allow_patterns=[f"{subdir}/*"])
                flatten_snapshot(dst, subdir)
                continue
            except Exception as exc:  # noqa: BLE001
                print(f"  ERROR: cannot list model files: {exc}")
                ok = False
                continue
        for remote in files:
            rel = remote[len(subdir) + 1:] if remote.startswith(subdir + "/") else remote
            ok = fetch(hf_urls(WHISPER_REPO, remote), dst / rel, 1) and ok
    return ok


def download_ai() -> bool:
    print("=== on-device AI models (SenseVoice / VAD / CAMPPlus / EmbeddingGemma) ===")
    AI.mkdir(parents=True, exist_ok=True)
    ok = True
    for rel, (minimum, urls) in AI_FILES.items():
        ok = fetch(urls, AI / rel, minimum) and ok
    return ok


def verify() -> bool:
    print("=== verification ===")
    failures = []

    for folder in WHISPER_FOLDERS:
        path = MODELS / folder
        files = [p for p in path.rglob("*") if p.is_file()] if path.exists() else []
        total = sum(p.stat().st_size for p in files)
        print(f"  {folder}: {len(files)} files, {total / 1_000_000:.1f} MB")
        if not files:
            failures.append(f"{folder} is empty")

    for rel, (minimum, _) in AI_FILES.items():
        path = AI / rel
        size = path.stat().st_size if path.exists() else 0
        print(f"  {rel}: {size} bytes (min {minimum})")
        if size < minimum:
            failures.append(f"{rel} missing or too small")

    gguf = AI / "embeddinggemma-300M-Q8_0.gguf"
    if gguf.exists():
        with gguf.open("rb") as handle:
            magic = handle.read(4)
        if magic != b"GGUF":
            failures.append("EmbeddingGemma GGUF magic is invalid")

    turbo = MODELS / "whisper-turbo"
    turbo_size = sum(p.stat().st_size for p in turbo.rglob("*") if p.is_file()) if turbo.exists() else 0
    if turbo_size < 500_000_000:
        failures.append(f"whisper-turbo is only {turbo_size} bytes (expected ~632 MB)")

    if failures:
        print("FAILED:")
        for item in failures:
            print(f"  - {item}")
        return False
    print("all models present and valid")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=["all", "whisper", "ai", "verify"], default="all")
    args = parser.parse_args()

    if not shutil.which("curl"):
        print("ERROR: curl is required", file=sys.stderr)
        return 2

    MODELS.mkdir(parents=True, exist_ok=True)
    ok = True
    if args.group in ("all", "whisper"):
        ok = download_whisper() and ok
    if args.group in ("all", "ai"):
        ok = download_ai() and ok
    if args.group in ("all", "verify"):
        ok = verify() and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
