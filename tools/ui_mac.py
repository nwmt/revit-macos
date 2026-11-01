# SPDX-License-Identifier: MIT
"""The Mac side of tools/ui_server.py: a picture of a window of one process, and whether a person is using the mouse.
Quartz through ctypes: this runs on the Python of the Command Line Tools, standard library only."""
import ctypes
import os
import struct
import subprocess

QUIET_S = 3
WAIT_S = 10
HID_STATE = 1             # kCGEventSourceStateHIDSystemState: what a person does, not what programs post
ANY_INPUT = 0xFFFFFFFF    # kCGAnyInputEventType
ON_SCREEN_ONLY_EXCLUDE_DESKTOP = 1 | 16
NORMAL_LAYER = 0


class NoPicture(Exception):
    pass


def pick(windows, pid, title):
    """The window number: this process's, normal layer, title starts so; the biggest, when there are several."""
    fit = [w for w in windows if w["pid"] == pid and w["layer"] == NORMAL_LAYER and (w["name"] or "").startswith(title)]
    return max(fit, key=lambda w: w["w"] * w["h"])["number"] if fit else None


def to_wine(x, y, shot_w, shot_h, rect):
    """A pixel of the picture of a window to a pixel of Wine's screen; rect is that window's (l, t, r, b)."""
    if not (0 <= x < shot_w and 0 <= y < shot_h):
        raise ValueError("the point is outside the picture")
    l, t, r, b = rect
    return l + int(x * (r - l) / shot_w), t + int(y * (b - t) / shot_h)


def wait_user_quiet(idle, button, sleep, clock):
    """True once nobody touched the mouse or keyboard for QUIET_S and no button is held; False after WAIT_S."""
    end = clock() + WAIT_S
    while True:
        if idle() >= QUIET_S and not button():
            return True
        if clock() >= end:
            return False
        sleep(0.25)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise ValueError("not a PNG")
    return struct.unpack(">II", head[16:24])


def screenshot(window, dst, run=None, asleep=None):
    """(width, height) of the picture of the window written to dst."""
    try:
        os.unlink(dst)
    except OSError:
        pass
    try:
        (run or _capture)(window, dst)
        return png_size(dst)
    except (OSError, ValueError, struct.error, subprocess.SubprocessError):
        if (asleep or display_asleep)():
            raise NoPicture("No picture: the display is asleep. Wake the Mac.")
        raise NoPicture("No picture of the window. The app that runs this needs Screen Recording: System Settings, "
                        "Privacy & Security, Screen Recording.")


def _capture(window, dst):
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", str(window), dst], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=20)


# ---- Quartz ----
def _frameworks():
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    vp, cl = ctypes.c_void_p, ctypes.c_long
    cg.CGWindowListCopyWindowInfo.restype = vp
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
    cg.CGEventSourceSecondsSinceLastEventType.argtypes = [ctypes.c_int32, ctypes.c_uint32]
    cg.CGEventSourceButtonState.restype = ctypes.c_bool
    cg.CGEventSourceButtonState.argtypes = [ctypes.c_int32, ctypes.c_uint32]
    cf.CFArrayGetCount.restype = cl
    cf.CFArrayGetCount.argtypes = [vp]
    cf.CFArrayGetValueAtIndex.restype = vp
    cf.CFArrayGetValueAtIndex.argtypes = [vp, cl]
    cf.CFDictionaryGetValue.restype = vp
    cf.CFDictionaryGetValue.argtypes = [vp, vp]
    cf.CFStringCreateWithCString.restype = vp
    cf.CFStringCreateWithCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [vp, ctypes.c_char_p, cl, ctypes.c_uint32]
    cf.CFNumberGetValue.restype = ctypes.c_bool
    cf.CFNumberGetValue.argtypes = [vp, ctypes.c_int, vp]
    cf.CFRelease.argtypes = [vp]
    return cg, cf


UTF8 = 0x08000100
SINT64 = 4
FLOAT64 = 13


def windows():
    """Every window on screen, as pick() wants them."""
    cg, cf = _frameworks()

    def key(s):
        return cf.CFStringCreateWithCString(None, s.encode(), UTF8)

    def number(d, k, kind=SINT64):
        v = cf.CFDictionaryGetValue(d, k)
        out = ctypes.c_double() if kind == FLOAT64 else ctypes.c_int64()
        if v:
            cf.CFNumberGetValue(v, kind, ctypes.byref(out))
        return out.value

    def text(d, k):
        v = cf.CFDictionaryGetValue(d, k)
        buf = ctypes.create_string_buffer(2048)
        return buf.value.decode("utf-8", "replace") if v and cf.CFStringGetCString(v, buf, 2048, UTF8) else ""

    knum, kpid, kname, klayer, kbounds = (key(s) for s in ("kCGWindowNumber", "kCGWindowOwnerPID", "kCGWindowName",
                                                           "kCGWindowLayer", "kCGWindowBounds"))
    kw, kh = key("Width"), key("Height")
    arr = cg.CGWindowListCopyWindowInfo(ON_SCREEN_ONLY_EXCLUDE_DESKTOP, 0)
    got = []
    if arr:
        for i in range(cf.CFArrayGetCount(arr)):
            d = cf.CFArrayGetValueAtIndex(arr, i)
            b = cf.CFDictionaryGetValue(d, kbounds)
            got.append({"number": number(d, knum), "pid": number(d, kpid), "name": text(d, kname), "layer": number(d, klayer),
                        "w": number(b, kw, FLOAT64) if b else 0, "h": number(b, kh, FLOAT64) if b else 0})
        cf.CFRelease(arr)
    return got


def window_id(pid, title):
    return pick(windows(), pid, title)


def display_asleep():
    cg = _frameworks()[0]
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    return bool(cg.CGDisplayIsAsleep(cg.CGMainDisplayID()))


def idle_seconds():
    return _frameworks()[0].CGEventSourceSecondsSinceLastEventType(HID_STATE, ANY_INPUT)


def button_down():
    cg = _frameworks()[0]
    return any(cg.CGEventSourceButtonState(HID_STATE, b) for b in (0, 1, 2))
