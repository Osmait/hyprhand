#!/usr/bin/env python3
"""Native keyboard wire tests against private fake Wayland/Hyprland sockets.

Run after zig build: python3 tests/keyboard_protocol.py
No compositor is started and no host socket is used. The fake server only
records requests and acknowledges sync callbacks; it cannot inject input.

Regression reference: Blender's keyboard_handle_key updates held-modifier
counters through keyboard_depressed_state_key_event; keyboard_handle_modifiers
updates the XKB mask without generating modifier key events.
https://github.com/blender/blender/blob/main/intern/ghost/intern/GHOST_SystemWayland.cc
https://xkbcommon.org/doc/current/group__state.html
"""
import array
import ctypes
import os
import socket
import struct
import threading
import unittest

import integration


def uints(*values):
    return struct.pack("=" + "I" * len(values), *values)


def string(value):
    data = value.encode() + b"\0"
    return uints(len(data)) + data + b"\0" * (-len(data) % 4)


def message(object_id, opcode, payload=b""):
    return uints(object_id, ((len(payload) + 8) << 16) | opcode) + payload


class FakeWayland:
    def __init__(self, fixture, mode=None):
        self.fixture = fixture
        self.mode = mode
        self.events = []
        self.maps = []
        self.errors = []
        self.running = True
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(fixture.root / "wayland-test"))
        self.server.listen()
        self.server.settimeout(0.05)
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()

    def close(self):
        self.running = False
        self.thread.join(timeout=5)
        self.server.close()
        if self.thread.is_alive():
            raise AssertionError("fake Wayland server failed to stop")
        if self.errors:
            raise AssertionError(self.errors)

    def serve(self):
        try:
            while self.running:
                try:
                    connection, _ = self.server.accept()
                except socket.timeout:
                    continue
                with connection:
                    self.handle(connection)
        except Exception as exc:
            self.errors.append(repr(exc))

    def handle(self, connection):
        connection.settimeout(0.05)
        objects = {1: "wl_display"}
        registry = None
        buffer = b""
        fds = []
        try:
            while self.running:
                try:
                    data, ancillary, flags, _ = connection.recvmsg(65536, socket.CMSG_SPACE(64 * 4))
                except socket.timeout:
                    continue
                if not data:
                    return
                assert not flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC)
                for level, kind, value in ancillary:
                    assert level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS
                    received = array.array("i")
                    received.frombytes(value)
                    fds.extend(received)
                buffer += data
                while len(buffer) >= 8:
                    object_id, header = struct.unpack_from("=II", buffer)
                    size, opcode = header >> 16, header & 0xFFFF
                    assert size >= 8 and size % 4 == 0
                    if len(buffer) < size:
                        break
                    payload, buffer = buffer[8:size], buffer[size:]
                    interface = objects[object_id]
                    if interface == "wl_display":
                        new_id, = struct.unpack("=I", payload)
                        if opcode == 1:
                            registry = new_id
                            objects[new_id] = "wl_registry"
                            connection.sendall(message(registry, 0, uints(10) +
                                                       string("zwp_virtual_keyboard_manager_v1") + uints(1)))
                            connection.sendall(message(registry, 0, uints(11) + string("wl_seat") + uints(7)))
                        else:
                            assert opcode == 0
                            connection.sendall(message(new_id, 0, uints(1)) +
                                               message(1, 1, uints(new_id)))
                    elif interface == "wl_registry":
                        assert opcode == 0
                        name, length = struct.unpack_from("=II", payload)
                        iface = payload[8:8 + length - 1].decode()
                        version, new_id = struct.unpack_from("=II", payload, 8 + ((length + 3) & ~3))
                        assert (name, iface) in ((10, "zwp_virtual_keyboard_manager_v1"), (11, "wl_seat"))
                        assert version > 0
                        objects[new_id] = iface
                    elif interface == "zwp_virtual_keyboard_manager_v1":
                        assert opcode == 0
                        seat, new_id = struct.unpack("=II", payload)
                        assert objects[seat] == "wl_seat"
                        objects[new_id] = "zwp_virtual_keyboard_v1"
                        if self.mode == "disconnect_create":
                            return
                    elif interface == "zwp_virtual_keyboard_v1":
                        if opcode == 0:
                            fmt, length = struct.unpack("=II", payload)
                            assert fmt == 1 and fds and length > 1
                            fd = fds.pop(0)
                            try:
                                text = os.pread(fd, length, 0)
                            finally:
                                os.close(fd)
                            assert len(text) == length and text[-1:] == b"\0"
                            self.maps.append(text)
                            self.events.append(("map", len(self.maps) - 1))
                        elif opcode == 1:
                            _, key, state = struct.unpack("=III", payload)
                            assert self.maps and state in (0, 1)
                            self.events.append(("key", key, state))
                            if state == 1 and self.mode == "lock":
                                self.fixture.locked = True
                            if state == 1 and key == 1 and self.mode == "focus_target":
                                self.fixture.active = "0x456"
                            if state == 1 and self.mode == "remove_seat":
                                connection.sendall(message(registry, 1, uints(11)))
                                self.mode = None
                        elif opcode == 2:
                            depressed, latched, locked, group = struct.unpack("=IIII", payload)
                            assert self.maps and (latched, locked, group) == (0, 0, 0)
                            self.events.append(("modifiers", depressed))
                        else:
                            assert opcode == 3
                            self.events.append(("destroy",))
                    else:
                        raise AssertionError(f"unexpected request {interface}:{opcode}")
        finally:
            for fd in fds:
                os.close(fd)


class XkbMap:
    """Decode exactly the serialized keymap sent through the memfd."""
    def __init__(self, text):
        self.lib = ctypes.CDLL("libxkbcommon.so.0")
        signatures = {
            "xkb_context_new": (ctypes.c_void_p, [ctypes.c_int]),
            "xkb_keymap_new_from_string": (ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]),
            "xkb_state_new": (ctypes.c_void_p, [ctypes.c_void_p]),
            "xkb_keymap_mod_get_index": (ctypes.c_uint32, [ctypes.c_void_p, ctypes.c_char_p]),
            "xkb_state_key_get_utf32": (ctypes.c_uint32, [ctypes.c_void_p, ctypes.c_uint32]),
            "xkb_state_key_get_one_sym": (ctypes.c_uint32, [ctypes.c_void_p, ctypes.c_uint32]),
            "xkb_state_update_mask": (ctypes.c_uint32, [ctypes.c_void_p] + [ctypes.c_uint32] * 6),
            "xkb_state_unref": (None, [ctypes.c_void_p]),
            "xkb_keymap_unref": (None, [ctypes.c_void_p]),
            "xkb_context_unref": (None, [ctypes.c_void_p]),
        }
        for name, (result, args) in signatures.items():
            function = getattr(self.lib, name)
            function.restype, function.argtypes = result, args
        self.context = self.lib.xkb_context_new(3)
        assert self.context
        self.map = self.lib.xkb_keymap_new_from_string(self.context, text, 1, 0)
        assert self.map
        self.state = self.lib.xkb_state_new(self.map)
        assert self.state

    def mask(self, name):
        index = self.lib.xkb_keymap_mod_get_index(self.map, name.encode())
        assert index < 32
        return 1 << index

    def close(self):
        self.lib.xkb_state_unref(self.state)
        self.lib.xkb_keymap_unref(self.map)
        self.lib.xkb_context_unref(self.context)


class KeyboardProtocol(unittest.TestCase):
    def setUp(self):
        # Reuse only the private fake IPC fixture, not its inherited test cases.
        self.fixture = integration.CLI()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        for name in ("WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
            self.fixture.env.pop(name, None)
        assert self.fixture.env["XDG_RUNTIME_DIR"] == str(self.fixture.root)
        assert self.fixture.env["WAYLAND_DISPLAY"] == "wayland-test"
        self.fixture.cli("enable")

    def start(self, mode=None):
        server = FakeWayland(self.fixture, mode)
        self.addCleanup(server.close)
        return server

    def key(self, chord, ok=True):
        return self.fixture.cli("key", chord, "--window", self.fixture.address,
                                "--session", "host", "--backend", "native", ok=ok)

    def assert_balanced(self, events):
        stack = []
        mask = 0
        for event in events:
            if event[0] == "key":
                if event[2]:
                    stack.append(event[1])
                else:
                    self.assertTrue(stack)
                    self.assertEqual(stack.pop(), event[1])
            elif event[0] == "modifiers":
                mask = event[1]
        self.assertEqual(stack, [])
        self.assertEqual(mask, 0)
        self.assertEqual(events[-1], ("destroy",))

    def test_blender_chord_has_actual_modifier_events_and_xkb_masks(self):
        server = self.start()
        self.key("ctrl+shift+alt+super+altgr+z")
        self.assertEqual(len(server.maps), 1)
        keymap = XkbMap(server.maps[0])
        self.addCleanup(keymap.close)
        mods = [("Control", 29, 0xFFE3), ("Shift", 42, 0xFFE1),
                ("Mod1", 56, 0xFFE9), ("Mod4", 125, 0xFFEB),
                ("Mod5", 100, 0xFE03)]
        expected = [("map", 0), ("modifiers", 0)]
        mask = 0
        for name, key, symbol in mods:
            self.assertEqual(keymap.lib.xkb_state_key_get_one_sym(keymap.state, key + 8), symbol)
            mask |= keymap.mask(name)
            expected.extend([("key", key, 1), ("modifiers", mask)])
        expected.extend([("key", 1, 1), ("key", 1, 0)])
        self.assertEqual(keymap.lib.xkb_state_key_get_utf32(keymap.state, 9), ord("z"))
        for name, key, _ in reversed(mods):
            mask &= ~keymap.mask(name)
            expected.extend([("key", key, 0), ("modifiers", mask)])
        expected.append(("destroy",))
        self.assertEqual(server.events, expected)
        self.assert_balanced(server.events)

    def test_unicode_text_survives_multiple_keymap_uploads(self):
        server = self.start()
        value = "".join(chr(0x400 + i) for i in range(257)) + "é中😀e\u0301\n\r\t\x1b"
        self.fixture.cli("type", "--text", value, "--window", self.fixture.address,
                         "--session", "host", "--backend", "native")
        self.assertEqual(len(server.maps), 3)
        decoded = []
        keymap = None
        try:
            for event in server.events:
                if event[0] == "map":
                    if keymap:
                        keymap.close()
                    keymap = XkbMap(server.maps[event[1]])
                elif event[0] == "key" and event[2]:
                    decoded.append(chr(keymap.lib.xkb_state_key_get_utf32(keymap.state, event[1] + 8)))
            self.assertEqual("".join(decoded), value.replace("\n", "\r"))
        finally:
            if keymap:
                keymap.close()
        self.assert_balanced(server.events)

    def test_shift_tab_and_shift_letters_translate_on_press_and_release(self):
        server = self.start()
        for chord, symbol, mask in (("Tab", 0xFF09, 0), ("shift+Tab", 0xFE20, 1),
                                    ("ctrl+shift+Tab", 0xFE20, 5), ("ctrl+shift+z", ord("Z"), 5)):
            with self.subTest(chord=chord):
                mark = len(server.events)
                self.key(chord)
                events = server.events[mark:]
                keymap = XkbMap(server.maps[-1])
                try:
                    depressed = 0
                    targets = []
                    for event in events:
                        if event[0] == "modifiers":
                            depressed = event[1]
                            keymap.lib.xkb_state_update_mask(keymap.state, depressed, 0, 0, 0, 0, 0)
                        elif event[0] == "key" and event[1] == 1:
                            targets.append((event[2], keymap.lib.xkb_state_key_get_one_sym(keymap.state, 9), depressed))
                    self.assertEqual(targets, [(1, symbol, mask), (0, symbol, mask)])
                    if mask & 1:
                        self.assertIn(("key", 42, 1), events)
                        self.assertIn(("key", 42, 0), events)
                finally:
                    keymap.close()
                self.assert_balanced(events)

    def test_session_lock_unwinds_modifiers_without_pressing_target(self):
        server = self.start("lock")
        result = self.key("ctrl+shift+z", ok=False)
        self.assertEqual(result["err"]["code"], "SessionLocked")
        self.assertNotIn(("key", 1, 1), server.events)
        self.assertIn(("key", 29, 1), server.events)
        self.assert_balanced(server.events)

    def test_seat_removal_unwinds_modifiers_without_pressing_target(self):
        server = self.start("remove_seat")
        result = self.key("ctrl+shift+z", ok=False)
        self.assertEqual(result["err"]["code"], "VirtualKeyboardUnavailable")
        self.assertNotIn(("key", 1, 1), server.events)
        self.assert_balanced(server.events)

    def test_failed_device_creation_sends_no_keymap_or_input(self):
        server = self.start("disconnect_create")
        result = self.key("ctrl+z", ok=False)
        self.assertEqual(result["err"]["code"], "WaylandUnavailable")
        self.assertEqual(server.events, [])

    def test_target_may_change_focus_and_still_releases_chord(self):
        server = self.start("focus_target")
        self.key("ctrl+o")
        self.assertEqual(self.fixture.active, "0x456")
        self.assertIn(("key", 1, 1), server.events)
        self.assert_balanced(server.events)


if __name__ == "__main__":
    unittest.main(verbosity=2)
