"""在非 macOS 环境验证附件导出及测试失败传播。"""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ipad_evidence", Path(__file__).with_name("test-ipad.py"))
ipad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipad)


def reference(identifier):
    return {"id": {"_value": identifier}}


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.bundle = self.directory / "result.xcresult"

    def test_exports_named_attachments_through_test_references(self):
        objects = {
            None: {
                "_type": {"name": "ActionsInvocationRecord"},
                "actions": {"_values": [{"actionResult": {"testsRef": reference("tests")}}]},
            },
            "tests": {"summaries": {"_values": [{"summaryRef": reference("summary")}]}},
            "summary": {
                "activitySummaries": {
                    "_values": [{
                        "attachments": {"_values": [
                            {"name": {"_value": name}, "payloadRef": reference(name + "-payload")}
                            for name in ipad.EVIDENCE_FILES
                        ]}
                    }]
                }
            },
        }
        with patch.object(ipad, "read_result", side_effect=lambda _, ref=None: objects[ref]), \
                patch.object(ipad.subprocess, "run") as run:
            exported = ipad.export_evidence(self.bundle, self.directory)
        self.assertEqual(exported, set(ipad.EVIDENCE_FILES))
        self.assertEqual(run.call_count, len(ipad.EVIDENCE_FILES))
        for call, (name, filename) in zip(run.call_args_list, ipad.EVIDENCE_FILES.items()):
            self.assertEqual(call.args[0], [
                "xcrun", "xcresulttool", "export", "--type", "file",
                "--path", str(self.bundle), "--id", name + "-payload",
                "--output-path", str(self.directory / filename),
            ])
            self.assertTrue(call.kwargs["check"])

    def test_ignores_unrequested_attachments_and_binary_payload_references(self):
        result = {
            "name": {"_value": "Screenshot"},
            "payloadRef": reference("binary"),
        }
        with patch.object(ipad, "read_result", return_value=result) as read, \
                patch.object(ipad.subprocess, "run") as run:
            self.assertEqual(ipad.export_evidence(self.bundle, self.directory), set())
        read.assert_called_once_with(self.bundle)
        run.assert_not_called()

    def test_visits_shared_references_once(self):
        root = {"actions": [
            {"testsRef": reference("tests")},
            {"testsRef": reference("tests")},
        ]}
        with patch.object(ipad, "read_result", side_effect=[root, {}]) as read:
            ipad.export_evidence(self.bundle, self.directory)
        self.assertEqual(read.call_count, 2)

    def test_reads_referenced_result_with_xcode_15_command(self):
        with patch.object(ipad.subprocess, "check_output", return_value=b'{"value": 1}') as output:
            self.assertEqual(ipad.read_result(self.bundle, "summary"), {"value": 1})
        output.assert_called_once_with([
            "xcrun", "xcresulttool", "get", "--path", str(self.bundle),
            "--format", "json", "--id", "summary",
        ])


class RunnerTests(unittest.TestCase):
    def setUp(self):
        devices = {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
            {"name": "iPhone 15", "udid": "phone"},
            {"name": "iPad Pro", "udid": "tablet"},
        ]}}
        output = patch.object(ipad.subprocess, "check_output", return_value=json.dumps(devices).encode())
        output.start()
        self.addCleanup(output.stop)
        exists = patch.object(Path, "exists", return_value=True)
        exists.start()
        self.addCleanup(exists.stop)

    def test_failed_ui_test_still_exports_evidence_and_remains_failed(self):
        result = subprocess.CompletedProcess(["xcodebuild"], 65)
        with patch.object(ipad.subprocess, "run", return_value=result), \
                patch.object(ipad, "export_evidence", return_value=set()) as export:
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                ipad.main()
        self.assertEqual(failure.exception.returncode, 65)
        export.assert_called_once()

    def test_success_requires_all_expected_attachments(self):
        result = subprocess.CompletedProcess(["xcodebuild"], 0)
        with patch.object(ipad.subprocess, "run", return_value=result), \
                patch.object(ipad, "export_evidence", return_value={"SPlayer-iPad-home"}):
            with self.assertRaisesRegex(RuntimeError, "SPlayer-iPad-library"):
                ipad.main()

    def test_success_never_relaunches_app_to_capture_a_different_screen(self):
        result = subprocess.CompletedProcess(["xcodebuild"], 0)
        with patch.object(ipad.subprocess, "run", return_value=result) as run, \
                patch.object(ipad, "export_evidence", return_value=set(ipad.EVIDENCE_FILES)):
            ipad.main()
        run.assert_called_once()
        self.assertIn("platform=iOS Simulator,id=tablet", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
