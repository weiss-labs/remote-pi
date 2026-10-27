#!/usr/bin/env python3
"""Guard against accidentally shipping known Apple system font files.

Scans actual .ipa/.app font names, not just pubspec.yaml. This is a small
packaging regression check, NOT a replacement for Apple's FontValidator.
No font bytes or third-party Python packages are bundled/installed.
"""
import json
import re
import struct
import sys
import zipfile
from pathlib import Path

FONT_SUFFIXES = {'.ttf', '.otf', '.ttc', '.otc'}
APPLE = re.compile(r'(?:sf[- ._]*(?:mono|pro|ns)|san francisco|new[- ._]*york|^menlo(?:[- ]|$)|^helvetica(?:[- ]|$)|apple)', re.I)


def font_names(data: bytes) -> list[str]:
    def u16(at):
        return struct.unpack_from('>H', data, at)[0]
    def u32(at):
        return struct.unpack_from('>I', data, at)[0]
    faces = [0]
    if data[:4] == b'ttcf':
        count = u32(8)
        if count > 256:
            raise ValueError('excessive collection size')
        faces = [u32(12 + i * 4) for i in range(count)]
    names = set()
    for face in faces:
        count = u16(face + 4)
        if count > 256:
            raise ValueError('excessive font table count')
        for i in range(count):
            record = face + 12 + i * 16
            if data[record:record + 4] != b'name':
                continue
            table, length = u32(record + 8), u32(record + 12)
            if table + length > len(data):
                raise ValueError('invalid name table bounds')
            strings = table + u16(table + 4)
            for j in range(u16(table + 2)):
                platform, _, _, name_id, size, off = struct.unpack_from('>6H', data, table + 6 + j * 12)
                if name_id not in (1, 4, 6, 16):
                    continue
                if strings + off + size > table + length:
                    raise ValueError('invalid font name bounds')
                raw = data[strings + off:strings + off + size]
                names.add(raw.decode('utf-16-be' if platform in (0, 3) else 'mac_roman'))
    if not names:
        raise ValueError('font has no readable family/name metadata')
    return sorted(names)


def scan(path: Path):
    if path.is_dir():
        for file in path.rglob('*'):
            if file.is_file() and file.suffix.lower() in FONT_SUFFIXES:
                yield str(file.relative_to(path)), file.read_bytes()
    else:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if Path(info.filename).suffix.lower() in FONT_SUFFIXES:
                    if info.file_size > 50 * 1024 * 1024:
                        raise ValueError('font exceeds audit size bound')
                    yield info.filename, archive.read(info)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: audit-ios-fonts.py <app.ipa|app.app>')
    rows, failures = [], []
    try:
        for filename, data in scan(Path(sys.argv[1])):
            names = font_names(data)
            rows.append({'path': filename, 'names': names})
            if APPLE.search(Path(filename).name) or any(APPLE.search(n) for n in names):
                failures.append(filename)
    except (ValueError, OSError, struct.error, UnicodeError, zipfile.BadZipFile) as error:
        print(json.dumps({'ok': False, 'error': str(error)}))
        return 1
    print(json.dumps({'ok': not failures, 'fonts': rows, 'disallowed_system_fonts': failures}, indent=2))
    return int(bool(failures))


if __name__ == '__main__':
    sys.exit(main())
