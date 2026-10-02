"""Archive-level tests without a Docker daemon or third-party dependencies."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

from tools import image_delta as delta


def layer(content, name="example"):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as tar:
        entry = tarfile.TarInfo(name)
        entry.size = len(content)
        entry.mode, entry.uid, entry.gid = 0o640, 123, 456
        tar.addfile(entry, io.BytesIO(content))
        # Symlinks belong inside layer tar streams and must survive unchanged.
        link = tarfile.TarInfo("link")
        link.type, link.linkname = tarfile.SYMTYPE, name
        tar.addfile(link)
    return stream.getvalue()


def sha(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def write_tar(path, files, compressed=False):
    with tarfile.open(path, "w:gz" if compressed else "w") as tar:
        for name, data in files:
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            tar.addfile(entry, io.BytesIO(data))


def saved_image(path, layers, *, arch="amd64", variant="", oci=False, tags=None):
    config = {
        "architecture": arch, "os": "linux", "variant": variant,
        "rootfs": {"type": "layers", "diff_ids": [sha(data) for data in layers]},
        "config": {"User": "10001:0", "Entrypoint": ["perl", "bin/server"],
                   "Env": ["HOME=/tmp"], "Healthcheck": {"Test": ["CMD", "check"]}},
        "history": [{"created_by": "test", "empty_layer": False} for _ in layers],
    }
    raw = json.dumps(config, indent=2).encode()
    config_name = "blobs/sha256/" + sha(raw)[7:] if oci else sha(raw)[7:] + ".json"
    files = [(config_name, raw)]
    names = []
    for index, data in enumerate(layers):
        # Docker/containerd save layouts can have gzip blobs named by compressed
        # digest; matching must use the config's uncompressed DiffIDs instead.
        payload = gzip.compress(data, mtime=0) if oci else data
        name = "blobs/sha256/" + sha(payload)[7:] if oci else f"legacy-{index}/layer.tar"
        names.append(name)
        if name not in {n for n, _ in files}:
            files.append((name, payload))
    files.append(("manifest.json", json.dumps([{
        "Config": config_name, "RepoTags": tags if tags is not None else ["example:local"], "Layers": names,
    }]).encode()))
    if oci:
        files.extend([("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", b'{}')])
    write_tar(path, files)
    return raw


def rewrite(source, target, replace=None, omit=(), extra=()):
    with tarfile.open(source) as tar:
        files = [(entry.name, tar.extractfile(entry).read()) for entry in tar if entry.isfile() and entry.name not in omit]
    files = [(name, (replace or {}).get(name, data)) for name, data in files]
    write_tar(target, files + list(extra), compressed=True)


class ImageDeltaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / "base.tar"
        self.image = self.root / "image.tar"
        self.bundle = self.root / "delta.tar.gz"
        self.output = self.root / "complete.tar"
        self.base_layers = [layer(b"base one"), layer(b"base two")]
        self.upper = [layer(b"app data"), layer(b"", ".wh.deleted-file")]
        saved_image(self.base, self.base_layers)
        self.config = saved_image(self.image, self.base_layers + self.upper)

    def export(self):
        return delta.export_delta(self.base, self.image, self.bundle)

    def assert_complete(self):
        with tarfile.open(self.output) as tar:
            manifest = json.load(tar.extractfile("manifest.json"))[0]
            self.assertEqual(tar.extractfile(manifest["Config"]).read(), self.config)
            for name, expected in zip(manifest["Layers"], self.base_layers + self.upper):
                # Byte identity includes whiteouts, modes, UIDs, and symlinks.
                self.assertEqual(tar.extractfile(name).read(), expected)
            return manifest

    def test_roundtrip_preserves_config_layers_and_tags(self):
        result = self.export()
        self.assertEqual(result["image_id"], sha(self.config))
        self.assertEqual(result["base_layers"], 2)
        self.assertEqual(result["transferred_layers"], 2)
        with tarfile.open(self.bundle) as tar:
            self.assertEqual(set(tar.getnames()), {"delta.json", "config.json"} |
                             {f"layers/{sha(payload)[7:]}.tar" for payload in self.upper})
        result = delta.assemble_delta(self.base, self.bundle, self.output)
        self.assertEqual(result["image_id"], sha(self.config))
        self.assertEqual(self.assert_complete()["RepoTags"], ["example:local"])

    def test_different_archive_layouts_and_layer_compression(self):
        for base_oci, image_oci in ((False, True), (True, False), (True, True)):
            with self.subTest(base_oci=base_oci, image_oci=image_oci):
                saved_image(self.base, self.base_layers, oci=base_oci)
                self.config = saved_image(self.image, self.base_layers + self.upper, oci=image_oci)
                self.export()
                # Target can export the same base with different blob names.
                saved_image(self.base, self.base_layers, oci=not base_oci)
                delta.assemble_delta(self.base, self.bundle, self.output, tag="restored:test")
                self.assertEqual(self.assert_complete()["RepoTags"], ["restored:test"])
                self.bundle.unlink()
                self.output.unlink()

    def test_wrong_base_fails_without_publishing_output(self):
        self.export()
        saved_image(self.base, list(reversed(self.base_layers)))
        with self.assertRaisesRegex(delta.DeltaError, "Base layer mismatch"):
            delta.assemble_delta(self.base, self.bundle, self.output)
        self.assertFalse(self.output.exists())

    def test_export_rejects_nonprefix_base(self):
        saved_image(self.base, [layer(b"unrelated")])
        with self.assertRaisesRegex(delta.DeltaError, "Base layer mismatch"):
            self.export()
        self.assertFalse(self.bundle.exists())

    def test_architecture_and_variant_must_match(self):
        for arch, variant in (("arm64", ""), ("amd64", "v3")):
            saved_image(self.base, self.base_layers, arch=arch, variant=variant)
            with self.assertRaisesRegex(delta.DeltaError, "platform mismatch"):
                self.export()

    def test_corrupt_upper_layer_rejected_and_no_partial_output(self):
        self.export()
        broken = self.root / "broken.tar.gz"
        name = f"layers/{sha(self.upper[0])[7:]}.tar"
        rewrite(self.bundle, broken, replace={name: layer(b"tampered")})
        with self.assertRaisesRegex(delta.DeltaError, "Layer hash mismatch"):
            delta.assemble_delta(self.base, broken, self.output)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob(".complete.tar.*")), [])

    def test_corrupt_base_payload_rejected_during_assembly(self):
        self.export()
        broken = self.root / "broken-base.tar"
        rewrite(self.base, broken, replace={"legacy-0/layer.tar": layer(b"tampered")})
        with self.assertRaisesRegex(delta.DeltaError, "Layer hash mismatch"):
            delta.assemble_delta(broken, self.bundle, self.output)
        self.assertFalse(self.output.exists())

    def test_corrupt_shared_payload_rejected_during_export(self):
        broken = self.root / "broken-image.tar"
        rewrite(self.image, broken, replace={"legacy-0/layer.tar": layer(b"tampered")})
        with self.assertRaisesRegex(delta.DeltaError, "Layer hash mismatch"):
            delta.export_delta(self.base, broken, self.bundle)
        self.assertFalse(self.bundle.exists())

    def test_config_checksum_verified(self):
        self.export()
        broken = self.root / "broken.tar.gz"
        rewrite(self.bundle, broken, replace={"config.json": self.config + b" "})
        with self.assertRaisesRegex(delta.DeltaError, "config hash mismatch"):
            delta.assemble_delta(self.base, broken, self.output)

    def test_source_config_checksum_verified(self):
        broken = self.root / "broken-image.tar"
        rewrite(self.image, broken, replace={sha(self.config)[7:] + ".json": self.config + b" "})
        with self.assertRaisesRegex(delta.DeltaError, "Source image config hash"):
            delta.export_delta(self.base, broken, self.bundle)

    def test_unsupported_compression_and_bundle_version(self):
        broken = self.root / "broken-image.tar"
        rewrite(self.image, broken, replace={"legacy-0/layer.tar": b'\x28\xb5\x2f\xfdunsupported'})
        with self.assertRaisesRegex(delta.DeltaError, "Unsupported layer compression"):
            delta.export_delta(self.base, broken, self.bundle)
        self.export()
        broken_bundle = self.root / "broken-delta.tar.gz"
        with tarfile.open(self.bundle) as tar:
            meta = json.load(tar.extractfile('delta.json'))
        meta['version'] = 999
        rewrite(self.bundle, broken_bundle, replace={'delta.json': json.dumps(meta).encode()})
        with self.assertRaisesRegex(delta.DeltaError, 'format/version'):
            delta.assemble_delta(self.base, broken_bundle, self.output)

    def test_missing_upper_and_unexpected_base_payload_rejected(self):
        self.export()
        broken = self.root / "broken.tar.gz"
        rewrite(self.bundle, broken, omit=[f"layers/{sha(self.upper[0])[7:]}.tar"])
        with self.assertRaisesRegex(delta.DeltaError, "layer payloads"):
            delta.assemble_delta(self.base, broken, self.output)
        rewrite(self.bundle, broken, extra=[(f"layers/{sha(self.base_layers[0])[7:]}.tar", self.base_layers[0])])
        with self.assertRaisesRegex(delta.DeltaError, "layer payloads"):
            delta.assemble_delta(self.base, broken, self.output)

    def test_existing_output_never_overwritten(self):
        self.bundle.write_bytes(b"keep me")
        with self.assertRaisesRegex(delta.DeltaError, "already exists"):
            self.export()
        self.assertEqual(self.bundle.read_bytes(), b"keep me")

    def test_repeated_layers_are_transferred_only_once(self):
        self.upper = [self.upper[0], self.upper[0], self.base_layers[0]]
        self.config = saved_image(self.image, self.base_layers + self.upper)
        self.assertEqual(self.export()["transferred_layers"], 1)
        delta.assemble_delta(self.base, self.bundle, self.output)
        self.assert_complete()

    def test_metadata_only_image_change(self):
        self.upper = []
        self.config = saved_image(self.image, self.base_layers, tags=[])
        self.assertEqual(self.export()["transferred_layers"], 0)
        delta.assemble_delta(self.base, self.bundle, self.output)
        self.assertEqual(self.assert_complete()["RepoTags"], [])

    def test_rejects_unsafe_duplicate_and_link_outer_members(self):
        for files in ([('../escape', b'bad')], [('same', b'a'), ('same', b'b')]):
            write_tar(self.base, files)
            with self.assertRaises(delta.DeltaError):
                self.export()
        with tarfile.open(self.base, "w") as tar:
            entry = tarfile.TarInfo("manifest.json")
            entry.type, entry.linkname = tarfile.SYMTYPE, "/etc/passwd"
            tar.addfile(entry)
        with self.assertRaisesRegex(delta.DeltaError, "regular file"):
            self.export()

    def test_rejects_multiple_images_and_oci_only(self):
        write_tar(self.base, [('manifest.json', b'[{},{}]')])
        with self.assertRaisesRegex(delta.DeltaError, "one image/platform"):
            self.export()
        write_tar(self.base, [('index.json', b'{}')])
        with self.assertRaisesRegex(delta.DeltaError, "OCI-only"):
            self.export()

    def test_cli_roundtrip_and_errors(self):
        tool = str(Path(delta.__file__).resolve())
        for arguments in (
            ['export', '--base', str(self.base), '--image', str(self.image), '--output', str(self.bundle)],
            ['assemble', '--base', str(self.base), '--delta', str(self.bundle), '--output', str(self.output)],
        ):
            result = subprocess.run([sys.executable, tool, *arguments], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['image_id'], sha(self.config))
        self.assert_complete()
        result = subprocess.run([sys.executable, tool, *arguments], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
