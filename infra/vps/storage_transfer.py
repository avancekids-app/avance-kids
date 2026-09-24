"""Back up Storage through its API, then restore and compare every object's hash.

Database dumps contain bucket/object metadata, not the file contents. Restore the
database first. This script never deletes source objects or existing backups.
"""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen


def request(url, key, path, method="GET", data=None, headers=None):
    auth = {"apikey": key, "Authorization": "Bearer " + key}
    with urlopen(Request(url.rstrip("/") + "/storage/v1/" + path,
                         data=data, headers=auth | (headers or {}), method=method),
                 timeout=120) as response:
        return response.read(), response.headers


def list_objects(url, key, bucket, prefix=""):
    offset = 0
    while True:
        payload = json.dumps({"prefix": prefix, "limit": 100, "offset": offset,
                              "sortBy": {"column": "name", "order": "asc"}}).encode()
        data, _ = request(url, key, "object/list/" + quote(bucket, safe=""),
                          "POST", payload, {"Content-Type": "application/json"})
        rows = json.loads(data)
        for row in rows:
            name = prefix + row["name"]
            if row.get("id") is None:
                yield from list_objects(url, key, bucket, name + "/")
            else:
                yield name
        if len(rows) < 100:
            return
        offset += len(rows)


def object_path(bucket, name):
    return quote(bucket, safe="") + "/" + quote(name, safe="/")


def backup(url, key, folder):
    folder.mkdir(parents=True, exist_ok=False)
    (folder / "objects").mkdir()
    data, _ = request(url, key, "bucket")
    manifest = {"source": url, "buckets": json.loads(data), "objects": []}
    for bucket in manifest["buckets"]:
        for name in list_objects(url, key, bucket["id"]):
            data, headers = request(url, key, "object/authenticated/" + object_path(bucket["id"], name))
            filename = f"objects/{len(manifest['objects']):08d}.bin"
            (folder / filename).write_bytes(data)
            manifest["objects"].append({
                "bucket": bucket["id"], "name": name, "file": filename,
                "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                "content_type": headers.get("Content-Type", "application/octet-stream"),
                "cache_control": headers.get("Cache-Control", "max-age=3600"),
            })
        print("Bucket backed up:", bucket["id"], flush=True)
    # Only a complete download gets a manifest that the restore command accepts.
    (folder / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print("Objects backed up:", len(manifest["objects"]))


def checked_file(folder, item):
    path = (folder / item["file"]).resolve()
    if not path.is_relative_to(folder.resolve()):
        raise ValueError("Object path leaves backup folder")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != item["sha256"]:
        raise ValueError("Backup checksum mismatch: " + item["file"])
    return data


def restore(url, key, folder):
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    # Check the entire local backup before writing the first remote object.
    for item in manifest["objects"]:
        checked_file(folder, item)
    for item in manifest["objects"]:
        path = object_path(item["bucket"], item["name"])
        request(url, key, "object/" + path, "POST", checked_file(folder, item), {
            "Content-Type": item["content_type"], "Cache-Control": item["cache_control"],
            "x-upsert": "true",
        })
        data, _ = request(url, key, "object/authenticated/" + path)
        if hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise ValueError("Restored object checksum mismatch: " + item["name"])
    print("Objects restored and verified:", len(manifest["objects"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("backup", "restore"))
    parser.add_argument("folder", type=Path)
    parser.add_argument("--url", required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    args = parser.parse_args()
    {"backup": backup, "restore": restore}[args.mode](
        args.url, args.key_file.read_text().strip(), args.folder)
