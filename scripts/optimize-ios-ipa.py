"""仅提高 IPA ZIP 压缩率，保留每个文件的内容、权限和符号链接信息。"""
import os
import sys
import zipfile

source, destination = sys.argv[1:]
if os.path.abspath(source) == os.path.abspath(destination):
    raise SystemExit("输入输出 IPA 必须不同")
with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, "w") as packed:
    for entry in original.infolist():
        packed.writestr(entry, original.read(entry), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination) as packed:
    if original.namelist() != packed.namelist():
        raise SystemExit("IPA 文件列表不一致")
    for entry in original.infolist():
        if original.read(entry) != packed.read(entry.filename):
            raise SystemExit(f"IPA 内容校验失败：{entry.filename}")
        if entry.external_attr != packed.getinfo(entry.filename).external_attr:
            raise SystemExit(f"IPA 权限校验失败：{entry.filename}")
before, after = os.path.getsize(source), os.path.getsize(destination)
print(f"IPA 压缩：{before:,} → {after:,} bytes（减少 {before - after:,} bytes）")
