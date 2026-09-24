import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import storage_transfer as transfer


class StorageTransferTest(unittest.TestCase):
    def test_nested_objects_and_pagination(self):
        def fake_request(url, key, path, method, data, headers):
            options = json.loads(data)
            if options["prefix"] == "folder/":
                rows = [{"id": "child", "name": "image.jpg"}]
            elif options["offset"] == 0:
                rows = [{"id": None, "name": "folder"}] + [
                    {"id": str(i), "name": str(i)} for i in range(99)]
            else:
                rows = [{"id": "last", "name": "last.png"}]
            return json.dumps(rows).encode(), {}

        with patch.object(transfer, "request", side_effect=fake_request):
            names = list(transfer.list_objects("https://example.test", "key", "avatars"))
        self.assertEqual(len(names), 101)
        self.assertEqual(names[0], "folder/image.jpg")
        self.assertEqual(names[-1], "last.png")

    def test_corrupt_backup_stops_before_any_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "file.bin").write_bytes(b"changed")
            item = {"file": "file.bin", "sha256": hashlib.sha256(b"original").hexdigest()}
            (folder / "manifest.json").write_text(json.dumps({"objects": [item]}))
            with patch.object(transfer, "request") as http:
                with self.assertRaisesRegex(ValueError, "checksum"):
                    transfer.restore("https://example.test", "key", folder)
                http.assert_not_called()


if __name__ == "__main__":
    unittest.main()
