#!/usr/bin/env python3

"""Validate AgentHub bundle and Sparkle release metadata.

The exported application's Info.plist is the authority for appcast versions.
This script deliberately supports numeric one-to-three-component versions only;
AgentHub release tags are stricter and must use ``vN.N.N``.
"""

from argparse import ArgumentParser
from pathlib import Path
import plistlib
import re
import sys
from typing import NamedTuple
import xml.etree.ElementTree as ElementTree


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")
RELEASE_TAG_PATTERN = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+)$")


class ValidationError(ValueError):
  """Release metadata violates the AgentHub Sparkle version contract."""


class ReleaseMetadata(NamedTuple):
  machine_version: str
  display_version: str


def _version_key(value, *, label="version"):
  if not isinstance(value, str) or VERSION_PATTERN.fullmatch(value) is None:
    raise ValidationError(
      f"{label} must be a numeric version with one to three components: {value!r}"
    )
  components = [int(component) for component in value.split(".")]
  return tuple(components + [0] * (3 - len(components)))


def compare_versions(left, right):
  """Compare the numeric version subset accepted by this release workflow."""
  left_key = _version_key(left, label="left version")
  right_key = _version_key(right, label="right version")
  return (left_key > right_key) - (left_key < right_key)


def is_update_available(installed_version, available_version):
  return compare_versions(available_version, installed_version) > 0


def normalize_release_tag(tag):
  match = RELEASE_TAG_PATTERN.fullmatch(tag)
  if match is None:
    raise ValidationError(
      f"release tag must use vN.N.N with numeric components: {tag!r}"
    )
  version = match.group(1)
  _version_key(version, label="release tag version")
  return version


def read_bundle_metadata(app_plist):
  plist_path = Path(app_plist)
  try:
    with plist_path.open("rb") as plist_file:
      data = plistlib.load(plist_file)
  except (OSError, plistlib.InvalidFileException) as error:
    raise ValidationError(f"cannot read application plist {plist_path}: {error}") from error

  machine_version = data.get("CFBundleVersion")
  display_version = data.get("CFBundleShortVersionString")
  _version_key(machine_version, label="CFBundleVersion")
  _version_key(display_version, label="CFBundleShortVersionString")
  return ReleaseMetadata(machine_version, display_version)


def _parse_xml(path, *, label):
  xml_path = Path(path)
  try:
    return ElementTree.parse(xml_path).getroot()
  except (OSError, ElementTree.ParseError) as error:
    raise ValidationError(f"cannot read {label} XML {xml_path}: {error}") from error


def _required_text(element, name, *, label):
  value = element.findtext(f"{{{SPARKLE_NAMESPACE}}}{name}")
  if value is None or not value.strip():
    raise ValidationError(f"{label} is missing sparkle:{name}")
  return value.strip()


def read_current_appcast_metadata(current_appcast):
  root = _parse_xml(current_appcast, label="current appcast")
  first_item = root.find("./channel/item")
  if first_item is None:
    raise ValidationError("current appcast does not contain a first channel item")
  machine_version = _required_text(
    first_item, "version", label="current appcast first item"
  )
  display_version = _required_text(
    first_item, "shortVersionString", label="current appcast first item"
  )
  _version_key(machine_version, label="current appcast sparkle:version")
  _version_key(
    display_version, label="current appcast sparkle:shortVersionString"
  )
  return ReleaseMetadata(machine_version, display_version)


def read_candidate_item_metadata(candidate_item):
  item = _parse_xml(candidate_item, label="candidate appcast item")
  if item.tag != "item":
    raise ValidationError("candidate appcast XML root must be an item")

  machine_version = _required_text(item, "version", label="candidate appcast item")
  display_version = _required_text(
    item, "shortVersionString", label="candidate appcast item"
  )
  _version_key(machine_version, label="candidate sparkle:version")
  _version_key(display_version, label="candidate sparkle:shortVersionString")

  enclosure = item.find("enclosure")
  if enclosure is None:
    raise ValidationError("candidate appcast item is missing enclosure")
  enclosure_machine = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}version")
  enclosure_display = enclosure.get(
    f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
  )
  if enclosure_machine != machine_version:
    raise ValidationError(
      "enclosure sparkle:version does not match the candidate top-level "
      f"sparkle:version: {enclosure_machine!r} != {machine_version!r}"
    )
  if enclosure_display != display_version:
    raise ValidationError(
      "enclosure sparkle:shortVersionString does not match the candidate "
      "top-level sparkle:shortVersionString: "
      f"{enclosure_display!r} != {display_version!r}"
    )
  return ReleaseMetadata(machine_version, display_version)


def validate_bundle(*, tag, app_plist, current_appcast):
  release_version = normalize_release_tag(tag)
  bundle = read_bundle_metadata(app_plist)
  current = read_current_appcast_metadata(current_appcast)

  if bundle.machine_version != release_version:
    raise ValidationError(
      "CFBundleVersion must match the release tag version: "
      f"{bundle.machine_version!r} != {release_version!r}"
    )
  if bundle.display_version != release_version:
    raise ValidationError(
      "CFBundleShortVersionString must match the release tag version: "
      f"{bundle.display_version!r} != {release_version!r}"
    )
  if compare_versions(bundle.machine_version, current.machine_version) <= 0:
    raise ValidationError(
      f"candidate CFBundleVersion {bundle.machine_version} must be greater than "
      f"current appcast sparkle:version {current.machine_version}"
    )
  return bundle


def validate_release(*, tag, app_plist, current_appcast, candidate_item):
  bundle = validate_bundle(
    tag=tag,
    app_plist=app_plist,
    current_appcast=current_appcast,
  )
  candidate = read_candidate_item_metadata(candidate_item)
  if candidate.machine_version != bundle.machine_version:
    raise ValidationError(
      "candidate sparkle:version must match CFBundleVersion: "
      f"{candidate.machine_version!r} != {bundle.machine_version!r}"
    )
  if candidate.display_version != bundle.display_version:
    raise ValidationError(
      "candidate sparkle:shortVersionString must match "
      "CFBundleShortVersionString: "
      f"{candidate.display_version!r} != {bundle.display_version!r}"
    )
  return bundle


def _write_github_output(path, values):
  output = "".join(f"{key}={value}\n" for key, value in values.items())
  if path is None:
    sys.stdout.write(output)
    return
  with Path(path).open("a", encoding="utf-8") as output_file:
    output_file.write(output)


def _build_parser():
  parser = ArgumentParser(description=__doc__)
  commands = parser.add_subparsers(dest="command", required=True)

  validate_tag = commands.add_parser("validate-tag")
  validate_tag.add_argument("tag")
  validate_tag.add_argument("--github-output")

  inspect_bundle = commands.add_parser("inspect-bundle")
  inspect_bundle.add_argument("--tag", required=True)
  inspect_bundle.add_argument("--app-plist", required=True)
  inspect_bundle.add_argument("--current-appcast", required=True)
  inspect_bundle.add_argument("--github-output")

  validate_release_parser = commands.add_parser("validate-release")
  validate_release_parser.add_argument("--tag", required=True)
  validate_release_parser.add_argument("--app-plist", required=True)
  validate_release_parser.add_argument("--current-appcast", required=True)
  validate_release_parser.add_argument("--candidate-item", required=True)
  return parser


def main(argv=None):
  args = _build_parser().parse_args(argv)
  try:
    if args.command == "validate-tag":
      version = normalize_release_tag(args.tag)
      _write_github_output(args.github_output, {"version": version})
    elif args.command == "inspect-bundle":
      metadata = validate_bundle(
        tag=args.tag,
        app_plist=args.app_plist,
        current_appcast=args.current_appcast,
      )
      _write_github_output(
        args.github_output,
        {
          "machine_version": metadata.machine_version,
          "display_version": metadata.display_version,
        },
      )
    else:
      metadata = validate_release(
        tag=args.tag,
        app_plist=args.app_plist,
        current_appcast=args.current_appcast,
        candidate_item=args.candidate_item,
      )
      print(
        "release metadata valid: "
        f"build={metadata.machine_version} display={metadata.display_version}"
      )
  except ValidationError as error:
    print(f"release metadata error: {error}", file=sys.stderr)
    return 1
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
