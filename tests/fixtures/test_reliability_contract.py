"""Offline safety/oracle checks. Never invokes deskctl, imports GTK, or opens UI.

Run: python3 -B tests/fixtures/test_reliability_contract.py
"""

import contextlib
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import live_reliability as live
import reliability as fixture


def options(**changes):
    values = dict(deskctl=Path("/nonexistent/deskctl"), session="test-managed",
                  events=Path("/nonexistent/events"), live=True, pointer=False,
                  scroll_mode="all", guard="stop")
    return SimpleNamespace(**(values | changes))


class Safety(unittest.TestCase):
    def setUp(self):
        self.run = patch.object(live.subprocess, "run", side_effect=AssertionError("Unexpected process launch")).start()
        self.popen = patch.object(live.subprocess, "Popen", side_effect=AssertionError("Unexpected process launch")).start()
        self.addCleanup(patch.stopall)

    def test_opt_in_and_session_gates_before_process_launch(self):
        invalid = (
            [], ["--live"], ["--session", "test-managed", "--events", "/missing"],
            ["--live", "--session", "host", "--events", "/missing"],
            ["--live", "--session", "HOST", "--events", "/missing"],
            ["--live", "--session", "../host", "--events", "/missing"],
        )
        for args in invalid:
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                live.main(args)
        self.run.assert_not_called()
        self.popen.assert_not_called()

    def test_environment_cannot_implicitly_authorize_session(self):
        with patch.dict(live.os.environ, {"DESKCTL_TEST_SESSION": "test-managed"}), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            live.main(["--live", "--events", "/missing"])
        self.run.assert_not_called()

    def test_pointer_cannot_bypass_review_with_piped_input(self):
        with patch.object(live.sys.stdin, "isatty", return_value=False), \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            live.main(["--live", "--session", "test-managed", "--events", "/missing", "--pointer"])
        self.run.assert_not_called()

    def test_no_enable_launch_focus_or_session_mutation(self):
        cli = live.Deskctl("/missing", "test-managed")
        for args in (("enable",), ("launch",), ("focus", "0x1"), ("workspace", "2"),
                     ("session", "destroy", "test-managed"), ("state", "--session", "host")):
            with self.subTest(args=args), self.assertRaises(RuntimeError):
                cli.call(*args)
        self.run.assert_not_called()

    def test_help_is_standalone_but_session_operations_are_scoped(self):
        cli = live.Deskctl("/missing", "test-managed")
        self.assertEqual(cli.argv("--help"), ["/missing", "--help"])
        self.assertEqual(cli.argv("doctor"), ["/missing", "doctor", "--session", "test-managed"])
        self.assertEqual(cli.argv("session", "inspect", "test-managed"),
                         ["/missing", "session", "inspect", "test-managed", "--session", "test-managed"])

    def test_stop_and_other_errors_latch_against_further_input(self):
        for code in ("ControlStopped", "humanstop", "SessionLocked", "Cancelled", "WindowNotFocused", "StaleObservation"):
            with self.subTest(code=code):
                cli = live.Deskctl("/missing", "test-managed")
                cli.decode(SimpleNamespace(returncode=1), json.dumps({"ok": False, "err": {"code": code}}), "", {code})
                for args in (("key", "a"), ("scroll",), ("enable",)):
                    with self.assertRaises(RuntimeError):
                        cli.call(*args)
        self.run.assert_not_called()

    def test_halted_cli_allows_only_scoped_read_and_stop(self):
        cli = live.Deskctl("/missing", "test-managed")
        cli.halted = True
        for command in ("doctor", "state", "stop"):
            self.assertEqual(cli.argv(command), ["/missing", command, "--session", "test-managed"])

    def test_cleanup_does_not_revoke_new_control_token(self):
        suite = live.Suite(options())
        suite.token = b"original"
        suite.token_path = Mock()
        suite.token_path.exists.return_value = True
        suite.token_path.read_bytes.return_value = b"renewed-by-operator"
        suite.cli.call = Mock()
        suite.close()
        suite.cli.call.assert_not_called()

    def test_cleanup_only_stops_borrowed_token(self):
        suite = live.Suite(options())
        suite.token = b"original"
        suite.token_path = Mock()
        suite.token_path.exists.return_value = True
        suite.token_path.read_bytes.return_value = b"original"
        suite.cli.call = Mock()
        suite.close()
        suite.cli.call.assert_called_once_with("stop")

    def test_human_token_revocation_is_terminal_before_state_or_input(self):
        suite = live.Suite(options())
        suite.token = b"original"
        suite.token_path = Mock()
        suite.token_path.read_bytes.side_effect = FileNotFoundError("human stop")
        with self.assertRaises(FileNotFoundError):
            suite.guard()
        self.assertTrue(suite.cli.halted)
        self.run.assert_not_called()

    def test_fixture_refuses_host_environment_before_gtk_import(self):
        with patch.dict(live.os.environ, {"XDG_CONFIG_HOME": "/home/user/.config"}, clear=True), \
                self.assertRaisesRegex(RuntimeError, "deskctl launch"):
            fixture.main(["--live", "--session", "test-managed", "--events", "/missing"])
        self.run.assert_not_called()

    def test_default_main_has_no_pointer_actions_and_always_cleans_up(self):
        suite = Mock()
        with patch.object(live, "Suite", return_value=suite), contextlib.redirect_stdout(io.StringIO()):
            suite.keyboard.side_effect = RuntimeError("modifier regression")
            with self.assertRaisesRegex(RuntimeError, "modifier regression"):
                live.main(["--live", "--session", "test-managed", "--events", "/missing"])
        suite.pointer.assert_not_called()
        suite.close.assert_called_once()


class Records:
    """Finite synthetic observer: oracle tests fail immediately instead of waiting."""

    def __init__(self, batch):
        self.records = []
        self.batch = batch

    def mark(self):
        return len(self.records)

    def poll(self):
        return self.records

    def deliver(self, *_args):
        self.records.extend(self.batch)
        return {"ok": True, "status": "sent"}

    def wait(self, mark, predicate, timeout=3):
        for event in self.records[mark:]:
            if predicate(event):
                return event
        raise RuntimeError("Missing receiver evidence")


class ReceiverOracle(unittest.TestCase):
    def batch(self, modifiers=4):
        return [
            {"event": "key-press", "key": "Control_L", "keycode": 37, "modifiers": 0},
            {"event": "modifiers", "modifiers": modifiers},
            {"event": "key-press", "key": "a", "keycode": 9, "modifiers": modifiers},
            {"event": "key-release", "key": "a", "keycode": 9, "modifiers": modifiers},
            {"event": "key-release", "key": "Control_L", "keycode": 37, "modifiers": modifiers},
            {"event": "snapshot", "selected": True},
        ]

    def check(self, batch):
        suite = live.Suite(options())
        suite.guard = Mock()
        suite.address = "0x123"
        suite.observer = Records(batch)
        suite.cli.call = suite.observer.deliver
        suite.key("ctrl+a", {"a"}, 4, lambda e: e["selected"])

    def test_actual_gtk_control_release_without_standalone_zero_callback_passes(self):
        # Matches reliability-040 records 68–72; release has the OLD mask.
        self.check(self.batch())

    def test_sent_acknowledgement_without_input_is_not_success(self):
        with self.assertRaises(RuntimeError):
            self.check([])

    def test_zero_modifiers_on_native_chord_is_regression(self):
        with self.assertRaisesRegex(RuntimeError, "GTK key modifiers"):
            self.check(self.batch(modifiers=0))

    def test_modifier_bits_without_real_transition_are_not_enough(self):
        batch = [e for e in self.batch() if e["event"] != "modifiers"]
        with self.assertRaisesRegex(RuntimeError, "no GTK modifier transition"):
            self.check(batch)

    def test_missing_target_or_modifier_release_fails(self):
        for batch in (self.batch()[:2], [e for e in self.batch() if
                                       not (e["event"] == "key-release" and e["key"] == "Control_L")]):
            with self.subTest(batch=batch), self.assertRaises(RuntimeError):
                self.check(batch)

    def test_mismatched_modifier_release_fails(self):
        batch = self.batch()
        batch[4] = dict(batch[4], keycode=38)
        with self.assertRaisesRegex(RuntimeError, "unmatched"):
            self.check(batch)

    def test_modifier_release_before_target_release_fails(self):
        batch = self.batch()
        batch[3], batch[4] = batch[4], batch[3]
        with self.assertRaisesRegex(RuntimeError, "out-of-order"):
            self.check(batch)

    def test_f12_probe_rejects_stuck_modifiers(self):
        for modifiers in (1, 4, 5):
            suite = live.Suite(options())
            suite.guard = Mock()
            suite.address = "0x123"
            suite.observer = Records([
                {"event": "key-press", "key": "F12", "keycode": 9, "modifiers": modifiers},
                {"event": "key-release", "key": "F12", "keycode": 9, "modifiers": modifiers},
            ])
            suite.cli.call = suite.observer.deliver
            with self.subTest(modifiers=modifiers), self.assertRaisesRegex(RuntimeError, "GTK key modifiers"):
                suite.key("F12", {"F12"}, 0)

    def test_home_precondition_makes_select_all_meaningful(self):
        suite = live.Suite(options())
        suite.key = Mock()
        suite.verified = Mock()
        suite.keyboard()
        calls = suite.key.call_args_list
        self.assertEqual([call.args[0] for call in calls[:3]], ["Home", "ctrl+a", "F12"])
        precondition = calls[0].args[3]
        self.assertFalse(precondition({"focus": "first", "cursor": 0, "text": "alpha", "selection": [0, 5]}))
        self.assertTrue(precondition({"focus": "first", "cursor": 0, "text": "alpha", "selection": []}))

    def test_stale_state_before_key_release_cannot_pass(self):
        batch = self.batch()
        batch.insert(0, batch.pop())
        with self.assertRaisesRegex(RuntimeError, "Missing receiver evidence"):
            self.check(batch)

    def test_alternating_wheel_and_surface_units_are_rejected(self):
        samples = [{"dy": 1.0, "unit": "wheel"}, {"dy": 15.0, "unit": "surface"}] * 4
        with self.assertRaisesRegex(RuntimeError, "Wrong GTK scroll units"):
            live.verify_scroll("wheel", samples)

    def test_extra_wheel_distance_is_rejected_even_with_matching_units(self):
        samples = [{"dy": 1.0, "unit": "wheel"}, {"dy": 15.0, "unit": "wheel"}] * 4
        with self.assertRaisesRegex(RuntimeError, "four requested detents"):
            live.verify_scroll("wheel", samples)

    def test_four_received_wheel_detents_pass(self):
        live.verify_scroll("wheel", [{"dy": 1.0, "unit": "wheel"}] * 4)

    def test_four_wheel_detents_then_late_surface_delta_fails(self):
        # Actual pre-fix endScroll regression: valid detents followed by one
        # spurious surface event, rather than a fallback pair to normalize away.
        samples = [{"dy": 1.0, "unit": "wheel"}] * 4 + [{"dy": 15.0, "unit": "surface"}]
        with self.assertRaisesRegex(RuntimeError, "Wrong GTK scroll units"):
            live.verify_scroll("wheel", samples)


class CancelLifecycle(unittest.TestCase):
    def setUp(self):
        self.run = patch.object(live.subprocess, "run", side_effect=AssertionError("Unexpected process launch")).start()
        self.popen = patch.object(live.subprocess, "Popen", side_effect=AssertionError("Unexpected process launch")).start()
        patch.object(live.time, "sleep").start()
        patch("builtins.input", side_effect=AssertionError("No real screenshot review in offline tests")).start()
        self.addCleanup(patch.stopall)

    def test_all_six_mode_window_variants_precede_terminal_guard(self):
        suite = live.Suite(options(pointer=True, guard="cancel"))
        suite.guard = Mock()
        suite.observer = Mock()
        suite.observer.mark.return_value = 0
        wheel = [{"event": "scroll", "dy": 1.0, "unit": "wheel"}] * 4
        surface = [{"event": "scroll", "dy": 2.0, "unit": "surface"}] * 4
        suite.observer.poll.side_effect = [surface, surface, wheel, wheel, surface, surface]
        timeline = []

        def reviewed(mode, duration, with_window=True):
            timeline.append((mode, duration, with_window))
            return ["scroll", "--scroll-mode", mode]

        suite.reviewed_scroll = reviewed  # Explicitly mock the human/UI boundary.
        suite.cli.call = Mock()
        suite.interrupt_scroll = lambda: timeline.append("terminal-cancel")
        with contextlib.redirect_stdout(io.StringIO()):
            suite.pointer()
        self.assertEqual(timeline, [
            ("auto", 500, True), ("auto", 500, False),
            ("wheel", 500, True), ("wheel", 500, False),
            ("continuous", 500, True), ("continuous", 500, False), "terminal-cancel",
        ])
        self.assertEqual(suite.cli.call.call_count, 6)
        self.assertTrue(all(call.args[0] == "scroll" for call in suite.cli.call.call_args_list))
        self.run.assert_not_called()
        self.popen.assert_not_called()

    def cancellation(self, result_code="Cancelled", trailing_scroll=False):
        suite = live.Suite(options(pointer=True, guard="cancel"))
        suite.reviewed_scroll = Mock(return_value=["scroll", "--scroll-mode", "continuous", "--duration-ms", "10000"])
        suite.observer = Mock()
        suite.observer.mark.side_effect = [0, 1]
        suite.observer.poll.return_value = [{"event": "scroll"}] + (
            [{"event": "scroll"}] if trailing_scroll else [{"event": "snapshot"}])
        suite.token = b"owned"
        suite.token_path = Mock()
        suite.token_path.exists.return_value = True
        suite.token_path.read_bytes.return_value = suite.token
        child = Mock()
        child.returncode = 1 if result_code else 0
        child.poll.return_value = child.returncode
        child.communicate.return_value = (json.dumps(
            {"ok": False, "err": {"code": result_code}} if result_code else {"ok": True}), "")
        self.popen.side_effect = None
        self.popen.return_value = child
        order = []
        suite.observer.wait.side_effect = lambda *_args, **_kwargs: order.append("received-axis")
        child.send_signal.side_effect = lambda sig: order.append(("signal", sig))

        def stop(argv, **_kwargs):
            self.assertEqual(argv, [str(suite.args.deskctl), "stop", "--session", "test-managed"])
            order.append("stop-owned-token")
            return SimpleNamespace(returncode=0, stdout='{"ok":true,"session_id":"test-managed"}', stderr="")

        self.run.side_effect = stop  # Every other process command fails the test.
        return suite, child, order

    def test_cancel_waits_for_input_then_sigterm_and_cleanup_without_enable(self):
        suite, child, order = self.cancellation()
        with contextlib.redirect_stdout(io.StringIO()):
            suite.interrupt_scroll()
        suite.reviewed_scroll.assert_called_once_with("continuous", 10000)
        self.assertEqual(order, ["received-axis", ("signal", live.signal.SIGTERM)])
        self.assertTrue(suite.cli.halted)
        child.send_signal.assert_called_once_with(live.signal.SIGTERM)
        self.assertEqual(self.popen.call_args.args[0][-2:], ["--session", "test-managed"])
        self.run.assert_not_called()  # No stop/enable before cancellation is verified.
        suite.close()
        self.assertEqual(order[-1], "stop-owned-token")
        self.assertEqual(self.run.call_count, 1)
        child.terminate.assert_not_called()
        child.kill.assert_not_called()
        for args in (("key", "F12"), ("scroll",), ("enable",)):
            with self.assertRaises(RuntimeError):
                suite.cli.call(*args)
        self.assertEqual(self.run.call_count, 1)

    def test_cancel_rejects_success_or_other_terminal_error(self):
        for code in (None, "ControlStopped", "WindowNotFocused"):
            suite, _, _ = self.cancellation(result_code=code)
            with self.subTest(code=code), self.assertRaises(RuntimeError):
                suite.interrupt_scroll()
            suite.close()

    def test_cancel_fails_if_received_scroll_continues(self):
        suite, _, _ = self.cancellation(trailing_scroll=True)
        with self.assertRaisesRegex(RuntimeError, "continued after interruption"):
            suite.interrupt_scroll()
        suite.close()

    def test_cancel_does_not_stop_a_replaced_token(self):
        suite, _, _ = self.cancellation()
        with contextlib.redirect_stdout(io.StringIO()):
            suite.interrupt_scroll()
        suite.token_path.read_bytes.return_value = b"new-authorization"
        suite.close()
        self.run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
