#!/usr/bin/env python3
"""Transfer a Docker image without its base layers; Python 3.9+, standard library.

Works on docker-save archives, never on Docker's private storage directories.
Layer payloads are opaque tar streams: whiteouts, ownership, and metadata stay
intact. No layer filesystem is extracted and no Docker commands are executed.
"""

import argparse
from contextlib import contextmanager
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
import tempfile


FORMAT = "docker-layer-delta"
VERSION = 1
CHUNK_SIZE = 1024 * 1024
METADATA_LIMIT = 4 * 1024 * 1024
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")


class DeltaError(ValueError):
    pass


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def member_name(name):
    if not isinstance(name, str) or not name:
        raise DeltaError("Archive member name must be a nonempty string")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or path.as_posix() == ".":
        raise DeltaError(f"Unsafe archive member name: {name!r}")
    return path.as_posix()


def layer_name(diff_id):
    return f"layers/{diff_id.removeprefix('sha256:')}.tar"


class Archive:
    def __init__(self, path):
        self.tar = tarfile.open(path, "r:*")
        self.files = {}
        try:
            for entry in self.tar:
                # No extract()/extractall(): outer paths are lookup keys only.
                if entry.isdir():
                    continue
                name = member_name(entry.name)
                if not entry.isfile():
                    raise DeltaError(f"Outer archive member must be a regular file: {name}")
                if name in self.files:
                    raise DeltaError(f"Duplicate archive member: {name}")
                self.files[name] = entry
        except Exception:
            self.tar.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.tar.close()

    def open(self, name):
        name = member_name(name)
        if name not in self.files:
            raise DeltaError(f"Missing archive member: {name}")
        return self.tar.extractfile(self.files[name])

    def metadata(self, name):
        with self.open(name) as stream:
            if self.files[member_name(name)].size > METADATA_LIMIT:
                raise DeltaError(f"Metadata exceeds {METADATA_LIMIT} bytes: {name}")
            return stream.read()

    def json(self, name):
        return json.loads(self.metadata(name))


def parse_config(raw):
    config = json.loads(raw)
    if not isinstance(config, dict):
        raise DeltaError("Image config must be a JSON object")
    for key in ("os", "architecture"):
        if not isinstance(config.get(key), str) or not config[key]:
            raise DeltaError(f"Image config requires {key}")
    if not isinstance(config.get("variant", ""), str):
        raise DeltaError("Image variant must be a string")
    rootfs = config.get("rootfs")
    if not isinstance(rootfs, dict) or rootfs.get("type") != "layers":
        raise DeltaError("Only layered image configurations are supported")
    diff_ids = rootfs.get("diff_ids")
    if not isinstance(diff_ids, list) or not all(isinstance(d, str) and DIGEST.fullmatch(d) for d in diff_ids):
        raise DeltaError("Image config requires a list of sha256 layer DiffIDs")
    platform = {key: config.get(key, "") for key in ("os", "architecture", "variant")}
    return platform, diff_ids


def validate_tags(tags):
    if not isinstance(tags, list) or not all(isinstance(tag, str) and tag for tag in tags):
        raise DeltaError("RepoTags must be a list of nonempty strings")
    return tags


class SavedImage:
    def __init__(self, archive):
        self.archive = archive
        if "manifest.json" not in archive.files:
            raise DeltaError("Expected a docker-save archive with manifest.json; OCI-only archives are unsupported")
        manifest = archive.json("manifest.json")
        if not isinstance(manifest, list) or len(manifest) != 1 or not isinstance(manifest[0], dict):
            raise DeltaError("Export exactly one image/platform per docker-save archive")
        entry = manifest[0]
        config_name = member_name(entry.get("Config"))
        self.raw_config = archive.metadata(config_name)
        self.image_id = digest(self.raw_config)
        named_digest = re.search(r"(?:^|/)([0-9a-f]{64})(?:\.json)?$", config_name)
        if named_digest and "sha256:" + named_digest[1] != self.image_id:
            raise DeltaError("Source image config hash does not match its content-addressed filename")
        self.platform, self.diff_ids = parse_config(self.raw_config)
        self.tags = validate_tags([] if entry.get("RepoTags") is None else entry["RepoTags"])
        self.layers = entry.get("Layers")
        if not isinstance(self.layers, list) or len(self.layers) != len(self.diff_ids):
            raise DeltaError("Manifest layer count does not match config DiffIDs")
        self.layers = [member_name(name) for name in self.layers]


def check_base(base, platform, required):
    if base.platform != platform:
        raise DeltaError(f"Base platform mismatch: expected {platform}, got {base.platform}")
    if base.diff_ids != required:
        raise DeltaError("Base layer mismatch: the target needs the exact ordered base DiffIDs, not just the same tag")


def read_layer(archive, name, expected, destination=None):
    """Hash the uncompressed layer while optionally spooling it to disk."""
    with archive.open(name) as raw:
        magic = raw.read(6)
        raw.seek(0)
        if magic.startswith((b"\x28\xb5\x2f\xfd", b"\xfd7zXZ", b"BZh")):
            raise DeltaError("Unsupported layer compression: use uncompressed or gzip layers from docker save")
        stream = gzip.GzipFile(fileobj=raw) if magic.startswith(b"\x1f\x8b") else raw
        hasher = hashlib.sha256()
        size = 0
        try:
            while block := stream.read(CHUNK_SIZE):
                hasher.update(block)
                size += len(block)
                if destination is not None:
                    destination.write(block)
        finally:
            if stream is not raw:
                stream.close()
        actual = "sha256:" + hasher.hexdigest()
        if actual != expected:
            raise DeltaError(f"Layer hash mismatch for {name}: expected {expected}, got {actual}")
        return size


@contextmanager
def atomic_output(path):
    """Publish only complete results, without overwriting an existing file."""
    path = Path(path)
    if path.exists() or path.is_symlink():
        raise DeltaError(f"Output already exists: {path}")
    with tempfile.NamedTemporaryFile(prefix=f".{path.name}.", dir=path.parent, delete=False) as temp:
        temporary = Path(temp.name)
        try:
            yield temp
            temp.flush()
            os.fsync(temp.fileno())
            # Same-filesystem hard link provides atomic, no-clobber publication.
            os.link(temporary, path)
        finally:
            temporary.unlink()


def add_bytes(tar, name, data):
    entry = tarfile.TarInfo(name)
    entry.mode = 0o644
    entry.size = len(data)
    tar.addfile(entry, io.BytesIO(data))


def json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def add_layer(tar, archive, source, diff_id):
    # A spool keeps RAM bounded and lets us verify a layer before archiving it.
    with tempfile.TemporaryFile() as layer:
        size = read_layer(archive, source, diff_id, layer)
        layer.seek(0)
        entry = tarfile.TarInfo(layer_name(diff_id))
        entry.mode = 0o644
        entry.size = size
        tar.addfile(entry, layer)


def export_delta(base_path, image_path, output):
    with Archive(base_path) as base_archive, Archive(image_path) as image_archive:
        base = SavedImage(base_archive)
        image = SavedImage(image_archive)
        count = len(base.diff_ids)
        check_base(base, image.platform, image.diff_ids[:count])
        base_ids = set(base.diff_ids)
        for source, diff_id in zip(base.layers, base.diff_ids):
            read_layer(base_archive, source, diff_id)
        metadata = {
            "format": FORMAT, "version": VERSION,
            "image_id": image.image_id, "base_diff_ids": base.diff_ids,
            "repo_tags": image.tags,
        }
        transferred = set()
        with atomic_output(output) as out:
            with gzip.GzipFile(filename="", fileobj=out, mode="wb", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|") as tar:
                    add_bytes(tar, "delta.json", json_bytes(metadata))
                    add_bytes(tar, "config.json", image.raw_config)
                    for source, diff_id in zip(image.layers, image.diff_ids):
                        if diff_id in base_ids or diff_id in transferred:
                            read_layer(image_archive, source, diff_id)
                        else:
                            add_layer(tar, image_archive, source, diff_id)
                            transferred.add(diff_id)
        return {
            "image_id": image.image_id, "platform": image.platform,
            "base_layers": count, "transferred_layers": len(transferred),
            "archive_bytes": Path(output).stat().st_size,
        }


def assemble_delta(base_path, delta_path, output, tag=None):
    with Archive(base_path) as base_archive, Archive(delta_path) as delta:
        base = SavedImage(base_archive)
        metadata = delta.json("delta.json")
        if not isinstance(metadata, dict) or metadata.get("format") != FORMAT or metadata.get("version") != VERSION:
            raise DeltaError("Unsupported delta bundle format/version")
        raw_config = delta.metadata("config.json")
        image_id = digest(raw_config)
        if metadata.get("image_id") != image_id:
            raise DeltaError("Image config hash mismatch")
        platform, diff_ids = parse_config(raw_config)
        required_base = metadata.get("base_diff_ids")
        check_base(base, platform, required_base)
        if diff_ids[:len(required_base)] != required_base:
            raise DeltaError("Delta base layers are not a prefix of the image layers")
        tags = validate_tags(metadata.get("repo_tags"))
        if tag is not None:
            tags = validate_tags([tag])
        expected_files = {"delta.json", "config.json"} | {
            layer_name(d) for d in diff_ids if d not in set(required_base)
        }
        if set(delta.files) != expected_files:
            raise DeltaError("Delta layer payloads do not match config: missing, unexpected, or included base layers")
        base_layers = dict(zip(base.diff_ids, base.layers))
        config_name = image_id.removeprefix("sha256:") + ".json"
        manifest = [{"Config": config_name, "RepoTags": tags, "Layers": [layer_name(d) for d in diff_ids]}]
        written = set()
        with atomic_output(output) as out:
            with tarfile.open(fileobj=out, mode="w|") as tar:
                add_bytes(tar, config_name, raw_config)
                add_bytes(tar, "manifest.json", json_bytes(manifest))
                for diff_id in diff_ids:
                    if diff_id in written:
                        continue
                    if diff_id in base_layers:
                        add_layer(tar, base_archive, base_layers[diff_id], diff_id)
                    else:
                        add_layer(tar, delta, layer_name(diff_id), diff_id)
                    written.add(diff_id)
        return {"image_id": image_id, "repo_tags": tags, "layers": len(diff_ids),
                "archive_bytes": Path(output).stat().st_size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    export = operations.add_parser("export", help="Create a gzip delta from base and application docker-save archives")
    export.add_argument("--base", required=True, type=Path)
    export.add_argument("--image", required=True, type=Path)
    export.add_argument("--output", required=True, type=Path)
    assemble = operations.add_parser("assemble", help="Reconstruct a complete docker-load archive using a local base")
    assemble.add_argument("--base", required=True, type=Path)
    assemble.add_argument("--delta", required=True, type=Path)
    assemble.add_argument("--output", required=True, type=Path)
    assemble.add_argument("--tag", help="Replace the source tags in the output archive; image ID stays unchanged")
    args = parser.parse_args()
    try:
        if args.operation == "export":
            result = export_delta(args.base, args.image, args.output)
        else:
            result = assemble_delta(args.base, args.delta, args.output, args.tag)
    except (DeltaError, OSError, tarfile.TarError, EOFError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"image_delta: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
