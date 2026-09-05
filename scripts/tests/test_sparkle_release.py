#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "sparkle_release"
VALIDATOR_PATH = ROOT / "scripts" / "validate_sparkle_release.py"

SPEC = importlib.util.spec_from_file_location("validate_sparkle_release", VALIDATOR_PATH)
if SPEC is None or SPEC.loader is None:
  raise RuntimeError(f"Unable to load validator from {VALIDATOR_PATH}")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class SparkleReleaseValidatorTests(unittest.TestCase):
  def validate(self, *, tag="v2.16.1", plist="matching-info.plist",
               item="matching-item.xml"):
    return VALIDATOR.validate_release(
      tag=tag,
      app_plist=FIXTURES / plist,
      current_appcast=FIXTURES / "current-appcast.xml",
      candidate_item=FIXTURES / item,
    )

  def test_matching_release_metadata_passes(self):
    metadata = self.validate()

    self.assertEqual(metadata.machine_version, "2.16.1")
    self.assertEqual(metadata.display_version, "2.16.1")

  def test_bundle_machine_version_mismatch_fails(self):
    with self.assertRaisesRegex(VALIDATOR.ValidationError, "CFBundleVersion"):
      self.validate(plist="build-mismatch-info.plist")

  def test_bundle_display_version_mismatch_fails(self):
    with self.assertRaisesRegex(VALIDATOR.ValidationError,
                                "CFBundleShortVersionString"):
      self.validate(plist="display-mismatch-info.plist")

  def test_candidate_machine_version_mismatch_fails(self):
    with self.assertRaisesRegex(VALIDATOR.ValidationError, "sparkle:version"):
      self.validate(item="machine-mismatch-item.xml")

  def test_candidate_display_version_mismatch_fails(self):
    with self.assertRaisesRegex(VALIDATOR.ValidationError,
                                "sparkle:shortVersionString"):
      self.validate(item="display-mismatch-item.xml")

  def test_enclosure_machine_version_mismatch_fails(self):
    with self.assertRaisesRegex(
      VALIDATOR.ValidationError, "enclosure sparkle:version"
    ):
      self.validate(item="enclosure-machine-mismatch-item.xml")

  def test_enclosure_display_version_mismatch_fails(self):
    with self.assertRaisesRegex(
      VALIDATOR.ValidationError, "enclosure sparkle:shortVersionString"
    ):
      self.validate(item="enclosure-display-mismatch-item.xml")

  def test_invalid_release_tag_fails(self):
    with self.assertRaisesRegex(VALIDATOR.ValidationError, "release tag"):
      self.validate(tag="release-2.16.1")

  def test_non_increasing_release_fails(self):
    with self.assertRaisesRegex(VALIDATOR.ValidationError, "greater than"):
      self.validate(
        tag="v2.16.0",
        plist="current-info.plist",
        item="current-item.xml",
      )

  def test_equal_machine_version_is_not_an_update(self):
    self.assertFalse(VALIDATOR.is_update_available("2.16.1", "2.16.1"))

  def test_older_machine_version_has_an_update(self):
    self.assertTrue(VALIDATOR.is_update_available("1", "2.16.1"))

  def test_multi_digit_components_compare_numerically(self):
    self.assertTrue(VALIDATOR.is_update_available("2.16.9", "2.16.10"))


class ReleaseWorkflowShapeTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls.workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text()

  def test_version_validation_precedes_release_publication(self):
    preparation = self.workflow.index("name: Prepare appcast item")
    validation = self.workflow.index("name: Validate release metadata")
    release = self.workflow.index("name: Create Release")
    appcast = self.workflow.index("name: Publish appcast item")

    self.assertLess(preparation, validation)
    self.assertLess(validation, release)
    self.assertLess(release, appcast)

  def test_build_receives_both_version_settings(self):
    self.assertIn('MARKETING_VERSION="$VERSION"', self.workflow)
    self.assertIn('CURRENT_PROJECT_VERSION="$VERSION"', self.workflow)

  def test_tag_commit_must_already_be_on_main(self):
    self.assertIn("fetch-depth: 0", self.workflow)
    self.assertIn(
      'git merge-base --is-ancestor "$GITHUB_SHA" origin/main',
      self.workflow,
    )

  def test_appcast_commit_receives_validated_version(self):
    publish_step = self.workflow[
      self.workflow.index("name: Publish appcast item"):
    ]
    self.assertIn(
      "VERSION: ${{ steps.release-version.outputs.version }}",
      publish_step,
    )

  def test_missing_sparkle_signature_fails_closed(self):
    self.assertIn("SPARKLE_PRIVATE_KEY is required for a release", self.workflow)
    self.assertIn("Sparkle sign_update tool was not found", self.workflow)
    self.assertNotIn("Skipping Sparkle signature generation", self.workflow)

  def test_appcast_uses_exported_bundle_versions(self):
    self.assertIn('<sparkle:version>${BUNDLE_VERSION}</sparkle:version>',
                  self.workflow)
    self.assertIn(
      '<sparkle:shortVersionString>${BUNDLE_SHORT_VERSION}</sparkle:shortVersionString>',
      self.workflow,
    )
    self.assertNotIn('<sparkle:version>${VERSION}</sparkle:version>',
                     self.workflow)
    self.assertNotIn(
      '<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>',
      self.workflow,
    )


class SparkleValidationWorkflowShapeTests(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls.workflow = (
      ROOT / ".github" / "workflows" / "validate-sparkle-release.yml"
    ).read_text()

  def test_validation_workflow_has_scoped_triggers_and_is_read_only(self):
    self.assertIn("workflow_dispatch:", self.workflow)
    self.assertIn("'validation/sparkle-v*'", self.workflow)
    self.assertIn("contents: read", self.workflow)
    self.assertNotIn("contents: write", self.workflow)

  def test_validation_workflow_builds_unsigned_and_checks_metadata(self):
    validation = self.workflow.index(
      "name: Resolve and validate candidate version"
    )
    build = self.workflow.index("name: Build unsigned Release archive")

    self.assertLess(validation, build)
    self.assertIn(
      'CANDIDATE_VERSION="${GITHUB_REF_NAME#validation/sparkle-v}"',
      self.workflow,
    )
    self.assertIn('echo "VERSION=${CANDIDATE_VERSION}" >> "$GITHUB_ENV"',
                  self.workflow)
    self.assertIn("CODE_SIGNING_ALLOWED=NO", self.workflow)
    self.assertIn("validate_sparkle_release.py validate-release", self.workflow)
    self.assertIn("AgentHub-unsigned-test-only", self.workflow)

  def test_validation_workflow_cannot_install_or_publish(self):
    self.assertNotRegex(
      self.workflow,
      r"(?m)^\s*(?:sudo\s+)?(?:cp|mv|ditto|install|rsync|rm)\b"
      r"[^\n]*\s+/Applications(?:/|\s|$)",
    )
    self.assertNotIn("git push", self.workflow)
    self.assertNotIn("action-gh-release", self.workflow)


class XcodeProjectVersionTests(unittest.TestCase):
  def test_checked_in_machine_and_display_versions_are_coherent(self):
    project = (
      ROOT / "app" / "AgentHub.xcodeproj" / "project.pbxproj"
    ).read_text()
    machine_versions = re.findall(
      r"CURRENT_PROJECT_VERSION = ([^;]+);", project
    )
    display_versions = re.findall(r"MARKETING_VERSION = ([^;]+);", project)

    self.assertTrue(machine_versions)
    self.assertEqual(sorted(machine_versions), sorted(display_versions))
    self.assertEqual(len(set(machine_versions)), 1)


class SparkleReleaseValidatorCLITests(unittest.TestCase):
  def run_validator(self, *arguments):
    return subprocess.run(
      [sys.executable, str(VALIDATOR_PATH), *arguments],
      cwd=ROOT,
      capture_output=True,
      text=True,
      check=False,
    )

  def release_arguments(self, *, tag="v2.16.1", plist="matching-info.plist",
                        item="matching-item.xml"):
    return (
      "validate-release",
      "--tag", tag,
      "--app-plist", str(FIXTURES / plist),
      "--current-appcast", str(FIXTURES / "current-appcast.xml"),
      "--candidate-item", str(FIXTURES / item),
    )

  def test_valid_release_exits_zero(self):
    result = self.run_validator(*self.release_arguments())

    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertIn("build=2.16.1 display=2.16.1", result.stdout)

  def test_invalid_tag_exits_one_with_diagnostic(self):
    result = self.run_validator(
      *self.release_arguments(tag="release-2.16.1")
    )

    self.assertEqual(result.returncode, 1)
    self.assertIn("release tag", result.stderr)

  def test_bundle_mismatch_exits_one_with_diagnostic(self):
    result = self.run_validator(
      *self.release_arguments(plist="build-mismatch-info.plist")
    )

    self.assertEqual(result.returncode, 1)
    self.assertIn("CFBundleVersion", result.stderr)

  def test_non_increasing_version_exits_one_with_diagnostic(self):
    result = self.run_validator(
      *self.release_arguments(
        tag="v2.16.0",
        plist="current-info.plist",
        item="current-item.xml",
      )
    )

    self.assertEqual(result.returncode, 1)
    self.assertIn("must be greater than", result.stderr)

  def test_inspect_bundle_emits_github_outputs(self):
    with tempfile.TemporaryDirectory() as temporary_directory:
      output_path = Path(temporary_directory) / "github-output"
      result = self.run_validator(
        "inspect-bundle",
        "--tag", "v2.16.1",
        "--app-plist", str(FIXTURES / "matching-info.plist"),
        "--current-appcast", str(FIXTURES / "current-appcast.xml"),
        "--github-output", str(output_path),
      )

      self.assertEqual(result.returncode, 0, result.stderr)
      self.assertEqual(
        output_path.read_text(),
        "machine_version=2.16.1\ndisplay_version=2.16.1\n",
      )


if __name__ == "__main__":
  unittest.main()
