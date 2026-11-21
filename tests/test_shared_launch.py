"""Attaching a gateway never quits an existing shared GUI or adopts stdio."""
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from mac.runtime import activate_bridge
activate_bridge()
from mac.shared_launch import SharedDesktop


class SharedAttachTests(unittest.TestCase):
    def setUp(self):
        self.desktop = SharedDesktop.__new__(SharedDesktop)
        self.desktop.gui = Path('/synthetic/ChatGPT.app/Contents/MacOS/ChatGPT')
        self.desktop.home = Path('/synthetic/home with spaces')
        self.desktop.control = self.desktop.home / 'app-server-control/app-server-control.sock'
        self.desktop.desktop = self.desktop.server = None
        self.desktop.attached_pid = None
        self.desktop.use_daemon = False
        self.endpoint = Path('/private/tmp/private-fixture/socket')

    def environment(self, home=None, url=None):
        return ('/synthetic/ChatGPT CODEX_HOME=' + str(home or self.desktop.home) +
                ' CODEX_APP_SERVER_WS_URL=' + (url or f'ws+unix://localhost{self.endpoint}:/rpc') +
                ' PATH=/usr/bin TMPDIR=/private/tmp\n')

    def test_exact_shared_home_and_socket_can_be_adopted_without_restarting_gui(self):
        with patch('bridge.desktop_app.DesktopApp.processes', return_value=[123]), \
                patch('mac.shared_launch.subprocess.run', return_value=SimpleNamespace(stdout=self.environment())), \
                patch('mac.shared_launch.private_socket', return_value=self.endpoint), \
                patch('mac.shared_launch.unix_connect') as connect, \
                patch('mac.shared_launch.subprocess.Popen') as launch:
            self.assertTrue(self.desktop.attach_existing())
            self.assertEqual((self.desktop.attached_pid, self.desktop.socket), (123, self.endpoint))
            connect.assert_called_once_with(self.endpoint)
            launch.assert_not_called()
            self.desktop.close()
            launch.assert_not_called()

    def test_missing_or_mismatched_environment_does_not_adopt_normal_desktop(self):
        for output in ('/synthetic/ChatGPT PATH=/usr/bin', self.environment(home='/other/home'),
                       self.environment(url='ws+unix://localhost/private/tmp/another:/rpc')):
            with patch('bridge.desktop_app.DesktopApp.processes', return_value=[123]), \
                    patch('mac.shared_launch.subprocess.run', return_value=SimpleNamespace(stdout=output)), \
                    patch('mac.shared_launch.private_socket', return_value=self.endpoint), \
                    patch('mac.shared_launch.unix_connect') as connect:
                self.assertFalse(self.desktop.attach_existing())
                self.assertIsNone(self.desktop.attached_pid)
                connect.assert_not_called()

    def test_attached_gui_exit_is_detected_and_close_never_signals_it(self):
        self.desktop.attached_pid = 123
        with patch('mac.shared_launch.os.kill') as kill:
            self.assertTrue(self.desktop.running())
            self.desktop.close()
            kill.assert_called_once_with(123, 0)
        with patch('mac.shared_launch.os.kill', side_effect=ProcessLookupError):
            self.assertFalse(self.desktop.running())
