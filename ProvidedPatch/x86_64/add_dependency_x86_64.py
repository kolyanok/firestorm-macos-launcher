"""Add a load dependency inside unused Mach-O header padding (x86_64 slice)."""
from pathlib import Path
import struct
import sys


def add_dependency(path, library_name):
    path = Path(path)
    data = bytearray(path.read_bytes())
    if data[:4] == bytes.fromhex("cafebabe"):
        count = struct.unpack_from(">I", data, 4)[0]
        slices = [struct.unpack_from(">IIIII", data, 8 + 20 * i) for i in range(count)]
        starts = [offset for cpu, subtype, offset, size, align in slices if cpu == 0x01000007]
    elif data[:4] == bytes.fromhex("cffaedfe"):
        starts = [0]
    else:
        raise ValueError("Unsupported executable format")
    if len(starts) != 1:
        raise ValueError("Expected exactly one x86_64 slice")
    base = starts[0]
    if data[base:base + 4] != bytes.fromhex("cffaedfe"):
        raise ValueError("Expected a little-endian 64-bit Mach-O slice")
    count, total = struct.unpack_from("<II", data, base + 16)
    cursor = base + 32
    first_section = len(data)
    encoded = library_name.encode() + b"\0"
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > base + 32 + total:
            raise ValueError("Invalid load command")
        if command == 12:
            name_offset = struct.unpack_from("<I", data, cursor + 8)[0]
            if data[cursor + name_offset:cursor + size].split(b"\0")[0] == encoded[:-1]:
                return False
        if command == 0x19:
            sections = struct.unpack_from("<I", data, cursor + 64)[0]
            for i in range(sections):
                offset = struct.unpack_from("<I", data, cursor + 72 + 80 * i + 48)[0]
                if offset:
                    first_section = min(first_section, base + offset)
        cursor += size
    if cursor != base + 32 + total:
        raise ValueError("Load command size does not match header")
    size = (24 + len(encoded) + 7) & ~7
    if cursor + size > first_section or any(data[cursor:cursor + size]):
        raise ValueError("Insufficient unused header padding")
    command = struct.pack("<IIIIII", 12, size, 24, 0, 0, 0) + encoded
    data[cursor:cursor + size] = command.ljust(size, b"\0")
    struct.pack_into("<II", data, base + 16, count + 1, total + size)
    path.write_bytes(data)
    return True


if __name__ == "__main__":
    print("dependency_added", add_dependency(sys.argv[1], sys.argv[2]))
