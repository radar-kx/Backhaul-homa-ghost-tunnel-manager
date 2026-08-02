#!/usr/bin/env python3
"""Verify keyboard navigation and scrollback-safe lifecycle in a real PTY."""

from __future__ import annotations

import errno
import os
import pathlib
import pty
import select
import signal
import sys
import tempfile
import termios
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent
MENU = ROOT / "bin" / "backhaul-menu"
HISTORY_MARKER = b"PRE_BH_SCROLLBACK_HISTORY"
PRE_BH_LINES = (
    HISTORY_MARKER.decode(),
    "History line 01",
    "History line 02",
    "History line 03",
    "History line 04",
    "History line 05",
    "History line 06",
    "History line 07",
    "History line 08",
    "History line 09",
    "History line 10",
    "History line 11",
    "History line 12",
    "root@test-server:~# bh",
)
PRE_BH_OUTPUT = ("\r\n".join(PRE_BH_LINES) + "\r\n").encode()
POST_BH_PROMPT = b"root@test-server:~# "


def run_session(
    payload: bytes,
    terminate_signal: int | None = None,
    unit_names: tuple[str, ...] = (),
    unit_role: str = "client",
    steps: tuple[tuple[bytes, bytes], ...] | None = None,
    terminal_rows: int = 40,
    terminal_columns: int = 80,
) -> bytes:
    with tempfile.TemporaryDirectory(prefix="homa-menu-pty-") as temp:
        root = pathlib.Path(temp)
        systemd = root / "etc/systemd/system"
        config = root / "etc/backhaul"
        systemd.mkdir(parents=True)
        config.mkdir(parents=True)

        for name in unit_names:
            config_file = config / f"{name}-{unit_role}.toml"
            config_file.write_text(
                f"[{unit_role}]\n"
                + (
                    'remote_addr = "192.0.2.10:9000"\n'
                    if unit_role == "client"
                    else 'bind_addr = "0.0.0.0:9000"\n'
                )
                + 'transport = "wsmux"\n'
                + 'token = "0123456789abcdef0123456789abcdef"\n'
                + (
                    'ports = ["8200=127.0.0.1:8090"]\n'
                    if unit_role == "server"
                    else ""
                )
            )
            (systemd / f"backhaul-{name}-{unit_role}.service").write_text(
                f"[Service]\nExecStart=/bin/true -c {config_file}\n"
            )

        env = os.environ.copy()
        env.update(
            {
                "TERM": "xterm-256color",
                "LINES": str(terminal_rows),
                "COLUMNS": str(terminal_columns),
                "BH_TERM_ROWS_OVERRIDE": str(terminal_rows),
                "BH_TERM_COLUMNS_OVERRIDE": str(terminal_columns),
                "BH_SKIP_ROOT_CHECK": "1",
                "BH_NO_SYSTEMD": "1",
                "BH_BIN": "/bin/true",
                "BH_SYSTEMD_DIR": str(systemd),
                "BH_CONFIG_DIR": str(config),
                "BH_PROJECT_DIR": str(ROOT),
                "BH_MANAGER_BIN": str(ROOT / "bin/backhaul-manager"),
                "BH_MENU_BIN": str(MENU),
                "BH_CRON_FILE": str(root / "etc/cron.d/health"),
                "BH_BACKUP_DIR": str(root / "backups"),
            }
        )

        pid, master = pty.fork()
        if pid == 0:
            os.write(1, PRE_BH_OUTPUT)
            os.execve(str(MENU), [str(MENU)], env)

        output = bytearray()
        terminal = NormalScreenModel(rows=terminal_rows, columns=terminal_columns)
        deadline = time.monotonic() + 8
        sent = False
        step_index = 0
        search_start = 0
        signal_sent = False
        cursor_reports_sent = 0
        status = None
        terminal_restored = False
        try:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
                    terminal.feed(chunk)

                    query_count = output.count(b"\x1b[6n")
                    while cursor_reports_sent < query_count:
                        os.write(
                            master,
                            f"\x1b[{terminal.row + 1};{terminal.column + 1}R".encode(),
                        )
                        cursor_reports_sent += 1

                if steps is not None and step_index < len(steps):
                    marker, step_payload = steps[step_index]
                    if marker in output[search_start:]:
                        os.write(master, step_payload)
                        step_index += 1
                        search_start = len(output)
                elif not sent and (
                    b"Select an option:" in output or b"Choice:" in output
                ):
                    if terminate_signal is not None:
                        os.kill(pid, terminate_signal)
                        signal_sent = True
                    else:
                        os.write(master, payload)
                    sent = True

                waited, child_status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    status = child_status
                    break
            else:
                raise AssertionError(
                    f"menu PTY session timed out; tail={bytes(output[-4000:])!r}"
                )
        finally:
            if status is None:
                try:
                    waited, child_status = os.waitpid(pid, os.WNOHANG)
                    if waited == pid:
                        status = child_status
                    else:
                        os.kill(pid, signal.SIGKILL)
                        _, status = os.waitpid(pid, 0)
                except ProcessLookupError:
                    pass
            try:
                local_flags = termios.tcgetattr(master)[3]
                terminal_restored = bool(
                    local_flags & termios.ECHO and local_flags & termios.ICANON
                )
            except OSError:
                terminal_restored = False
            try:
                os.close(master)
            except OSError:
                pass

        if (
            terminate_signal is None
            and status is not None
            and os.waitstatus_to_exitcode(status) != 0
        ):
            raise AssertionError(
                f"menu exited with {os.waitstatus_to_exitcode(status)}: {output!r}"
            )
        if terminate_signal is not None and not signal_sent:
            raise AssertionError("signal test never reached the menu prompt")
        if steps is not None and step_index != len(steps):
            raise AssertionError(
                f"scripted PTY flow completed only {step_index}/{len(steps)} steps"
            )
        if not terminal_restored:
            raise AssertionError("terminal echo/canonical mode was not restored")
        return bytes(output)


def run_log_interrupt_session() -> bytes:
    with tempfile.TemporaryDirectory(prefix="homa-menu-log-pty-") as temp:
        root = pathlib.Path(temp)
        systemd = root / "etc/systemd/system"
        config = root / "etc/backhaul"
        fake_bin = root / "fake-bin"
        systemd.mkdir(parents=True)
        config.mkdir(parents=True)
        fake_bin.mkdir()

        config_file = config / "test-client.toml"
        config_file.write_text(
            '[client]\n'
            'remote_addr = "192.0.2.10:9000"\n'
            'transport = "wsmux"\n'
            'token = "0123456789abcdef0123456789abcdef"\n'
        )
        (systemd / "backhaul-test-client.service").write_text(
            f"[Service]\nExecStart=/bin/true -c {config_file}\n"
        )
        journalctl = fake_bin / "journalctl"
        journalctl.write_text(
            "#!/usr/bin/env bash\n"
            "trap 'exit 130' INT\n"
            "while true; do sleep 1; done\n"
        )
        journalctl.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "TERM": "xterm-256color",
                "LINES": "40",
                "COLUMNS": "80",
                "BH_TERM_ROWS_OVERRIDE": "40",
                "PATH": f"{fake_bin}:{env['PATH']}",
                "BH_SKIP_ROOT_CHECK": "1",
                "BH_NO_SYSTEMD": "1",
                "BH_BIN": "/bin/true",
                "BH_SYSTEMD_DIR": str(systemd),
                "BH_CONFIG_DIR": str(config),
                "BH_PROJECT_DIR": str(ROOT),
                "BH_MANAGER_BIN": str(ROOT / "bin/backhaul-manager"),
                "BH_MENU_BIN": str(MENU),
                "BH_CRON_FILE": str(root / "etc/cron.d/health"),
                "BH_BACKUP_DIR": str(root / "backups"),
            }
        )

        pid, master = pty.fork()
        if pid == 0:
            os.write(1, PRE_BH_OUTPUT)
            os.execve(str(MENU), [str(MENU)], env)

        output = bytearray()
        terminal = NormalScreenModel(rows=40)
        cursor_reports_sent = 0
        phase = 0
        status = None
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
                    terminal.feed(chunk)

                    query_count = output.count(b"\x1b[6n")
                    while cursor_reports_sent < query_count:
                        os.write(
                            master,
                            f"\x1b[{terminal.row + 1};{terminal.column + 1}R".encode(),
                        )
                        cursor_reports_sent += 1

                if phase == 0 and b"Select an option:" in output:
                    os.write(master, b"2\n")
                    phase = 1
                elif phase == 1 and b"Tunnel management:" in output:
                    os.write(master, b"2\n")
                    phase = 2
                elif phase == 2 and b"Press Ctrl+C to return directly" in output:
                    time.sleep(0.1)
                    os.killpg(pid, signal.SIGINT)
                    phase = 3
                elif phase == 3 and output.count(b"Tunnel management:") >= 2:
                    os.write(master, b"0\n")
                    phase = 4
                elif phase == 4 and output.count(b"Select an option:") >= 2:
                    os.write(master, b"0\n")
                    phase = 5

                waited, child_status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    status = child_status
                    break
            else:
                raise AssertionError("live-log Ctrl+C PTY session timed out")
        finally:
            try:
                os.close(master)
            except OSError:
                pass
            if status is None:
                waited, child_status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    status = child_status
                else:
                    os.kill(pid, signal.SIGKILL)
                    _, status = os.waitpid(pid, 0)

        if phase != 5:
            raise AssertionError(f"live-log Ctrl+C flow stopped at phase {phase}: {output!r}")
        if status is None or os.waitstatus_to_exitcode(status) != 0:
            raise AssertionError(f"live-log Ctrl+C flow exited abnormally: {output!r}")
        return bytes(output)


def assert_normal_screen_lifecycle(output: bytes, label: str) -> None:
    title = b"HOMA GHOST TUNNEL MANAGER"
    forbidden = (
        b"\x1b[?1047h",
        b"\x1b[?1047l",
        b"\x1b[3J",
    )

    for sequence in forbidden:
        if sequence in output:
            raise AssertionError(
                f"{label}: forbidden terminal sequence found: {sequence!r}"
            )
    if output.count(b"\x1b[?1049h") != 1 or output.count(b"\x1b[?1049l") != 1:
        raise AssertionError(f"{label}: alternate-screen entry/exit is not balanced")
    if HISTORY_MARKER not in output or title not in output:
        raise AssertionError(f"{label}: history marker or title is missing")
    if output.index(HISTORY_MARKER) > output.index(title):
        raise AssertionError(f"{label}: pre-bh history was emitted after the menu")
    if output.index(b"\x1b[?1049h") > output.index(title):
        raise AssertionError(f"{label}: menu rendered before alternate-screen entry")

    logo_lines = (
        b" _   _  ___  __  __    _",
        b"| | | |/ _ \\|  \\/  |  / \\",
        b"| |_| | | | | |\\/| | / _ \\",
        b"|  _  | |_| | |  | |/ ___ \\",
        b"|_| |_|\\___/|_|  |_/_/   \\_\\",
    )
    for line in logo_lines:
        if line not in output:
            raise AssertionError(f"{label}: incomplete HOMA logo; missing {line!r}")

    final_leave = output.rfind(b"\x1b[?1049l")
    if final_leave < output.rfind(title):
        raise AssertionError(f"{label}: alternate screen closed before final menu cleanup")
    if title in output[final_leave + len(b"\x1b[?1049l") :]:
        raise AssertionError(f"{label}: title was printed again after final cleanup")


def assert_compact_menu_lifecycle(output: bytes, label: str) -> None:
    titles = (b"HOMA GHOST v", b"HOMA GHOST TUNNEL MANAGER v")
    title = next((candidate for candidate in titles if candidate in output), None)
    forbidden = (
        b"\x1b[?1047h",
        b"\x1b[?1047l",
        b"\x1b[3J",
    )
    for sequence in forbidden:
        if sequence in output:
            raise AssertionError(
                f"{label}: forbidden terminal sequence found: {sequence!r}"
            )
    if output.count(b"\x1b[?1049h") != 1 or output.count(b"\x1b[?1049l") != 1:
        raise AssertionError(f"{label}: alternate-screen entry/exit is not balanced")
    if HISTORY_MARKER not in output or title is None:
        raise AssertionError(f"{label}: compact title or history marker is missing")
    if output.index(HISTORY_MARKER) > output.index(title):
        raise AssertionError(f"{label}: pre-bh history was emitted after the menu")
    if output.rfind(b"\x1b[?1049l") < output.rfind(title):
        raise AssertionError(f"{label}: compact menu remained visible after exit")



class NormalScreenModel:
    """Minimal VT normal-buffer model for the control sequences used by bh."""

    def __init__(self, rows: int, columns: int = 80) -> None:
        self.rows = rows
        self.columns = columns
        self.history: list[str] = []
        self.screen = [[" "] * columns for _ in range(rows)]
        self.row = 0
        self.column = 0

    def _line_text(self, row: int) -> str:
        return "".join(self.screen[row]).rstrip()

    def _line_feed(self) -> None:
        if self.row == self.rows - 1:
            self.history.append(self._line_text(0))
            self.screen.pop(0)
            self.screen.append([" "] * self.columns)
        else:
            self.row += 1

    @staticmethod
    def _parameters(raw: bytes) -> list[int]:
        if raw.startswith(b"?"):
            raw = raw[1:]
        if not raw:
            return []
        result = []
        for item in raw.split(b";"):
            try:
                result.append(int(item) if item else 0)
            except ValueError:
                result.append(0)
        return result

    def _erase_display(self, mode: int) -> None:
        if mode == 2:
            self.screen = [[" "] * self.columns for _ in range(self.rows)]
            return
        if mode == 0:
            for column in range(self.column, self.columns):
                self.screen[self.row][column] = " "
            for row in range(self.row + 1, self.rows):
                self.screen[row] = [" "] * self.columns
            return
        if mode == 1:
            for row in range(0, self.row):
                self.screen[row] = [" "] * self.columns
            for column in range(0, self.column + 1):
                self.screen[self.row][column] = " "

    def _erase_line(self, mode: int) -> None:
        if mode == 2:
            start, end = 0, self.columns
        elif mode == 1:
            start, end = 0, min(self.column + 1, self.columns)
        else:
            start, end = min(self.column, self.columns), self.columns
        for column in range(start, end):
            self.screen[self.row][column] = " "

    def _csi(self, parameters: bytes, final: int) -> None:
        values = self._parameters(parameters)
        first = values[0] if values else 0
        if final in (ord("H"), ord("f")):
            row = values[0] if values and values[0] else 1
            column = values[1] if len(values) > 1 and values[1] else 1
            self.row = min(max(row - 1, 0), self.rows - 1)
            self.column = min(max(column - 1, 0), self.columns - 1)
        elif final == ord("A"):
            self.row = max(0, self.row - (first or 1))
        elif final == ord("B"):
            self.row = min(self.rows - 1, self.row + (first or 1))
        elif final == ord("C"):
            self.column = min(self.columns - 1, self.column + (first or 1))
        elif final == ord("D"):
            self.column = max(0, self.column - (first or 1))
        elif final == ord("J"):
            self._erase_display(first)
        elif final == ord("K"):
            self._erase_line(first)

    def feed(self, output: bytes) -> None:
        index = 0
        while index < len(output):
            byte = output[index]
            if byte == 0x1B and index + 1 < len(output):
                if output[index + 1] == ord("["):
                    final_index = index + 2
                    while (
                        final_index < len(output)
                        and not 0x40 <= output[final_index] <= 0x7E
                    ):
                        final_index += 1
                    if final_index >= len(output):
                        return
                    self._csi(
                        output[index + 2 : final_index],
                        output[final_index],
                    )
                    index = final_index + 1
                    continue
                index += 2
                continue
            if byte == ord("\r"):
                self.column = 0
            elif byte == ord("\n"):
                self._line_feed()
            elif byte == ord("\b"):
                self.column = max(0, self.column - 1)
            elif byte == ord("\t"):
                self.column = min(
                    self.columns - 1,
                    ((self.column // 8) + 1) * 8,
                )
            elif 0x20 <= byte <= 0x7E:
                self.screen[self.row][self.column] = chr(byte)
                if self.column < self.columns - 1:
                    self.column += 1
            index += 1


def assert_menu_absent_from_scrollback(
    output: bytes,
    label: str,
    terminal_rows: int,
    terminal_columns: int = 80,
) -> None:
    enter = output.find(b"\x1b[?1049h")
    leave = output.rfind(b"\x1b[?1049l")
    if enter < 0 or leave <= enter:
        raise AssertionError(f"{label}: alternate-screen boundaries are missing")
    if HISTORY_MARKER not in output[:enter]:
        raise AssertionError(f"{label}: pre-homa history marker moved into the UI buffer")
    if b"HOMA GHOST" in output[leave + len(b"\x1b[?1049l"):]:
        raise AssertionError(f"{label}: menu text leaked after alternate-screen exit")


def assert_compact_shell_round_trip(
    output: bytes,
    label: str,
    terminal_rows: int,
    terminal_columns: int = 80,
) -> None:
    """Alternate-screen exit must be the final UI terminal-mode transition."""
    leave = output.rfind(b"\x1b[?1049l")
    if leave < 0 or b"\x1b[?1049h" in output[leave + 8:]:
        raise AssertionError(f"{label}: alternate screen was re-entered after exit")


def down(count: int) -> bytes:
    return b"\x1b[B" * count


def up(count: int = 1) -> bytes:
    return b"\x1b[A" * count


normal = run_session(b"4\n0\n0\n")
assert_normal_screen_lifecycle(normal, "normal exit")
assert_menu_absent_from_scrollback(normal, "normal exit", terminal_rows=40)
assert_compact_shell_round_trip(normal, "normal exit", terminal_rows=40)
if normal.count(b"HOMA GHOST TUNNEL MANAGER") != 2:
    raise AssertionError("normal exit: expected exactly two clean main-menu renders")

short_terminal = run_session(b"0\n", terminal_rows=24)
assert_normal_screen_lifecycle(short_terminal, "24-row Termius flow")
assert_menu_absent_from_scrollback(
    short_terminal,
    "24-row Termius flow",
    terminal_rows=24,
)
assert_compact_shell_round_trip(
    short_terminal,
    "24-row Termius flow",
    terminal_rows=24,
)

terminated = run_session(b"", terminate_signal=signal.SIGTERM)
assert_normal_screen_lifecycle(terminated, "SIGTERM exit")
assert_menu_absent_from_scrollback(terminated, "SIGTERM exit", terminal_rows=40)

interrupted = run_session(b"", terminate_signal=signal.SIGINT)
assert_normal_screen_lifecycle(interrupted, "SIGINT exit")

hung_up = run_session(b"", terminate_signal=signal.SIGHUP)
assert_normal_screen_lifecycle(hung_up, "SIGHUP exit")

arrow_exit = run_session(up() + b"\n")
assert_normal_screen_lifecycle(arrow_exit, "Up-arrow wrapped exit")
if arrow_exit.count(b"HOMA GHOST TUNNEL MANAGER") != 1:
    raise AssertionError("Up-arrow did not wrap from the first option to Exit")
for unchanged_option in (
    b"2) Manage tunnels",
    b"3) Show all tunnel statuses",
    b"4) Health check and auto-repair",
):
    if arrow_exit.count(unchanged_option) != 1:
        raise AssertionError(
            "arrow navigation repainted an unchanged menu row: "
            f"{unchanged_option!r}"
        )

rapid_arrows = run_session(down(200) + up(200) + up() + b"\n")
assert_normal_screen_lifecycle(rapid_arrows, "rapid held-arrow coalescing")
for stable_option in (b"2) Manage tunnels", b"3) Show all tunnel statuses"):
    if rapid_arrows.count(stable_option) > 2:
        raise AssertionError(
            f"rapid arrows caused redundant option repaint: {stable_option!r}"
        )

all_top_menus = run_session(
    b"",
    unit_names=("test",),
    terminal_rows=24,
    steps=(
        (b"Select an option:", b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", down(1) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", down(2) + b"\n"),
        (b"Press Enter to continue...", b"\n"),
        (b"Select an option:", down(3) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", down(4) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", down(5) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", down(6) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", down(7) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", down(8) + b"\n"),
        (b"Update Manager files from GitHub? [y/N]:", b"n\n"),
        (b"Press Enter to continue...", b"\n"),
        (b"Select an option:", up() + b"\n"),
    ),
)
assert_normal_screen_lifecycle(all_top_menus, "all top-level arrow navigation")
assert_menu_absent_from_scrollback(
    all_top_menus,
    "all top-level arrow navigation",
    terminal_rows=24,
)
for expected in (
    b"Create a new tunnel",
    b"Tunnel management: backhaul-test-client.service",
    b"=== Tunnel status ===",
    b"Health check and auto-repair",
    b"Health-check cron",
    b"Backups and restore",
    b"Network diagnostics",
    b"Backhaul core",
    b"Update Manager files from GitHub?",
):
    if expected not in all_top_menus:
        raise AssertionError(f"arrow flow did not reach {expected!r}")
if b"^[[A" in all_top_menus or b"^[[B" in all_top_menus:
    marker = b"^[[A" if b"^[[A" in all_top_menus else b"^[[B"
    position = all_top_menus.index(marker)
    raise AssertionError(
        "arrow keys were echoed as raw escape text: "
        f"{all_top_menus[max(0, position - 160):position + 160]!r}"
    )

nested_menus = run_session(
    b"",
    unit_names=("test",),
    unit_role="server",
    terminal_rows=24,
    steps=(
        (b"Select an option:", down(1) + b"\n"),
        (b"Selection:", down(3) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Selection:", down(4) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", up() + b"\n"),
    ),
)
assert_normal_screen_lifecycle(nested_menus, "nested arrow navigation")
assert_menu_absent_from_scrollback(
    nested_menus,
    "nested arrow navigation",
    terminal_rows=24,
)
for expected in (b"Service controls:", b"Port mappings:"):
    if expected not in nested_menus:
        raise AssertionError(f"nested arrow flow did not reach {expected!r}")

multi_unit = run_session(
    b"",
    unit_names=("first", "second"),
    terminal_rows=24,
    steps=(
        (b"Select an option:", down(1) + b"\n"),
        (b"Select a tunnel to manage:", down(1) + b"\n"),
        (b"Selection:", up() + b"\n"),
        (b"Select an option:", up() + b"\n"),
    ),
)
assert_normal_screen_lifecycle(multi_unit, "multi-unit arrow navigation")
assert_menu_absent_from_scrollback(
    multi_unit,
    "multi-unit arrow navigation",
    terminal_rows=24,
)
if b"Tunnel management: backhaul-second-client.service" not in multi_unit:
    raise AssertionError("Down-arrow did not select the second service")

application_cursor = run_session(b"\x1bOB\x1bOA\x1bOA\n")
assert_normal_screen_lifecycle(application_cursor, "application-cursor arrows")

modified_cursor = run_session(b"\x1b[1;5B\x1b[1;5A\x1b[A\n")
assert_normal_screen_lifecycle(modified_cursor, "modified CSI arrows")

invalid_number = run_session(
    b"",
    steps=(
        (b"Select an option:", b"99\n"),
        (b"Press Enter to continue...", b"\n"),
        (b"Select an option:", b"0\n"),
    ),
)
assert_normal_screen_lifecycle(invalid_number, "invalid numeric selection")
if b"Invalid selection." not in invalid_number:
    raise AssertionError("invalid numeric selection was not rejected")

backspace_number = run_session(b"9\x7f0\n")
assert_normal_screen_lifecycle(backspace_number, "numeric backspace")
if backspace_number.count(b"HOMA GHOST TUNNEL MANAGER") != 1:
    raise AssertionError("Backspace did not remove the typed menu number")

escape_back = run_session(
    b"",
    steps=(
        (b"Select an option:", b"\n"),
        (b"Selection:", b"\x1b"),
        (b"Select an option:", b"\x1b"),
    ),
)
assert_normal_screen_lifecycle(escape_back, "Escape back and exit")

log_interrupt = run_log_interrupt_session()
assert_normal_screen_lifecycle(log_interrupt, "live-log Ctrl+C")
if log_interrupt.count(b"Tunnel management:") < 2:
    raise AssertionError("live-log Ctrl+C did not return to tunnel management")

for rows, columns, payload in (
    (12, 80, b"0\n"),
    (16, 48, up() + b"\n"),
    (20, 36, down(9) + b"\n"),
    (24, 40, up() + b"\n"),
    (32, 36, down(9) + b"\n"),
):
    label = f"compact terminal {rows}x{columns}"
    compact = run_session(
        payload,
        terminal_rows=rows,
        terminal_columns=columns,
    )
    assert_compact_menu_lifecycle(compact, label)
    if rows >= 20:
        for logo_line in (
            b" _   _  ___  __  __    _",
            b"| | | |/ _ \\|  \\/  |  / \\",
            b"| |_| | | | | |\\/| | / _ \\",
            b"|  _  | |_| | |  | |/ ___ \\",
            b"|_| |_|\\___/|_|  |_/_/   \\_\\",
        ):
            if logo_line not in compact:
                raise AssertionError(
                    f"{label}: narrow terminal lost the complete HOMA logo: "
                    f"{logo_line!r}"
                )
    elif b"[ HOMA ]" not in compact:
        raise AssertionError(f"{label}: ultra-compact HOMA badge is missing")
    assert_menu_absent_from_scrollback(
        compact,
        label,
        terminal_rows=rows,
        terminal_columns=columns,
    )
    assert_compact_shell_round_trip(
        compact,
        label,
        terminal_rows=rows,
        terminal_columns=columns,
    )

print("Menu PTY tests passed.")
