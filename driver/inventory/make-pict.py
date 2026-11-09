"""Write a PICT 2 file that holds one 32-bit bitmap.

Usage: make-pict.py OUT.pict

The file is the 512-byte header that a PICT file on disk carries, then the picture: the version 2 opcodes, an
extended header at 72 dpi, a clip region of the frame, one DirectBitsRect (0x009A) of WIDTH x HEIGHT pixels and
the end opcode. The image is a black letter F with a black square at the lower right on white, so a mirror or a
rotation of the import shows.

The rows are stored unpacked (packType 1). macOS ImageIO draws nothing for a BitsRect (0x0090) or a
PackBitsRect (0x0098), and it stops reading the picture at that opcode.
"""
import struct
import sys

WIDTH, HEIGHT = 23, 17


def black(x, y):
    return x < 4 or (y < 4 and x < 16) or (7 <= y < 10 and x < 11) or (18 <= x < 22 and 12 <= y < 16)


def rect(top, left, bottom, right):
    return struct.pack(">4h", top, left, bottom, right)


def pixels():
    return b"".join(b"\0\0\0\0" if black(x, y) else b"\0\xff\xff\xff" for y in range(HEIGHT) for x in range(WIDTH))


def picture():
    frame = rect(0, 0, HEIGHT, WIDTH)
    dpi = 72 << 16
    body = struct.pack(">HH", 0x0011, 0x02FF)
    body += struct.pack(">HhhII", 0x0C00, -2, 0, dpi, dpi) + frame + struct.pack(">I", 0)
    body += struct.pack(">HH", 0x001E, 0x0001) + struct.pack(">H", 10) + frame
    pixmap = struct.pack(">IH", 0xFF, WIDTH * 4 | 0x8000) + frame
    pixmap += struct.pack(">hhIIIhhhhIII", 0, 1, 0, dpi, dpi, 16, 32, 3, 8, 0, 0, 0)
    body += struct.pack(">H", 0x009A) + pixmap + frame + frame + struct.pack(">H", 0) + pixels()
    body += struct.pack(">H", 0x00FF)
    pic = frame + body
    return struct.pack(">H", (len(pic) + 2) & 0xFFFF) + pic


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as f:
        f.write(bytes(512) + picture())


if __name__ == "__main__":
    main()
