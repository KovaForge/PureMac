#!/usr/bin/env python3
"""Fixture tests for puremaccli first-party CLI behavior.

These tests intentionally exercise the built CLI as a black box so OpenClaw/Hermes
can rely on stable JSON contracts rather than Swift internals.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def built_cli_path(repo: Path) -> Path:
    env_path = os.environ.get("PUREMACCTL_BIN")
    if env_path:
        return Path(env_path)
    return repo / "build" / "Build" / "Products" / "Debug" / "puremaccli"


def run_cli(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    cli = built_cli_path(repo)
    return subprocess.run(
        [str(cli), *args],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def make_dotnet_fixture(root: Path) -> None:
    project = root / "SampleApp"
    (project / "bin" / "Debug").mkdir(parents=True)
    (project / "obj" / "Debug").mkdir(parents=True)
    (project / "SampleApp.csproj").write_text("<Project Sdk=\"Microsoft.NET.Sdk\" />\n")
    (project / "bin" / "Debug" / "app.dll").write_bytes(b"x" * 4096)
    (project / "obj" / "Debug" / "cache.bin").write_bytes(b"y" * 2048)

    # A random bin directory without project context must not be considered safe.
    unrelated = root / "random" / "bin"
    unrelated.mkdir(parents=True)
    (unrelated / "keep.txt").write_text("not a build artifact")


def make_cache_fixture(home: Path) -> None:
    nuget = home / ".nuget" / "packages" / "example" / "1.0.0"
    nuget.mkdir(parents=True)
    (nuget / "example.nupkg").write_bytes(b"n" * 8192)
    app_cache = home / "Library" / "Caches" / "ExampleIDE"
    app_cache.mkdir(parents=True)
    (app_cache / "cache.bin").write_bytes(b"c" * (2 * 1024 * 1024))


def test_scan_finds_only_project_build_artifacts(repo: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="puremaccli-fixture-") as tmp:
        fixture = Path(tmp)
        make_dotnet_fixture(fixture)
        result = run_cli(repo, "scan", "--home", str(fixture), "--root", str(fixture), "--json")
        assert result.returncode == 0, result.stderr
        payload = json.loads(result.stdout)
        paths = {item["path"] for item in payload["items"]}
        expected_bin = str((fixture / "SampleApp" / "bin").resolve())
        expected_obj = str((fixture / "SampleApp" / "obj").resolve())
        unrelated_bin = str((fixture / "random" / "bin").resolve())
        assert expected_bin in paths
        assert expected_obj in paths
        assert unrelated_bin not in paths
        assert payload["candidateCount"] == 2
        assert payload["totalBytes"] >= 6144


def test_dry_run_does_not_delete_and_execute_deletes(repo: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="puremaccli-fixture-") as tmp:
        fixture = Path(tmp)
        make_dotnet_fixture(fixture)
        dry = run_cli(repo, "clean", "--home", str(fixture), "--root", str(fixture), "--min-free-percent", "100", "--dry-run", "--json")
        assert dry.returncode == 0, dry.stderr
        assert (fixture / "SampleApp" / "bin").exists()
        assert (fixture / "SampleApp" / "obj").exists()

        execute = run_cli(repo, "clean", "--home", str(fixture), "--root", str(fixture), "--min-free-percent", "100", "--execute", "--json")
        assert execute.returncode == 0, execute.stderr
        payload = json.loads(execute.stdout)
        assert payload["mode"] == "execute"
        assert payload["deletedCount"] == 2
        assert not (fixture / "SampleApp" / "bin").exists()
        assert not (fixture / "SampleApp" / "obj").exists()
        assert (fixture / "random" / "bin").exists()


def test_scan_and_clean_include_developer_package_caches(repo: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="puremaccli-fixture-") as tmp:
        fixture = Path(tmp)
        make_cache_fixture(fixture)
        scan = run_cli(repo, "scan", "--home", str(fixture), "--root", str(fixture), "--json")
        assert scan.returncode == 0, scan.stderr
        payload = json.loads(scan.stdout)
        cache_paths = {str(Path(item["path"]).resolve()) for item in payload["items"] if item["category"] == "developerPackageCaches"}
        user_cache_paths = {str(Path(item["path"]).resolve()) for item in payload["items"] if item["category"] == "userCaches"}
        assert str((fixture / ".nuget" / "packages").resolve()) in cache_paths
        assert str((fixture / "Library" / "Caches" / "ExampleIDE").resolve()) in user_cache_paths

        execute = run_cli(repo, "clean", "--home", str(fixture), "--root", str(fixture), "--min-free-percent", "100", "--execute", "--json")
        assert execute.returncode == 0, execute.stderr
        assert not (fixture / ".nuget" / "packages").exists()
        assert not (fixture / "Library" / "Caches" / "ExampleIDE").exists()


def test_clean_short_circuits_when_already_above_threshold(repo: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="puremaccli-fixture-") as tmp:
        fixture = Path(tmp)
        make_dotnet_fixture(fixture)
        result = run_cli(repo, "clean", "--home", str(fixture), "--root", str(fixture), "--min-free-percent", "0", "--execute", "--json")
        assert result.returncode == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["status"] == "no_action_needed"
        assert payload["candidateCount"] == 0
        assert (fixture / "SampleApp" / "bin").exists()


def test_manifest_is_valid_first_party_contract(repo: Path) -> None:
    manifest = repo / "manifests" / "puremaccli.manifest.json"
    payload = json.loads(manifest.read_text())
    assert payload["schemaVersion"] == 1
    assert payload["name"] == "puremaccli"
    assert payload["firstPartyFor"] == ["OpenClaw", "Hermes"]
    command_names = {command["name"] for command in payload["commands"]}
    assert {"status", "scan", "clean", "install-agent", "uninstall-agent"}.issubset(command_names)
    assert payload["output"]["format"] == "json"
    assert payload["safety"]["dryRunDefault"] is True
    assert payload["successCriteria"]["minimumFreeSpacePercent"] == 10


def test_rejects_broad_cleanup_roots(repo: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="puremaccli-fixture-") as tmp:
        fixture = Path(tmp)
        result = run_cli(repo, "scan", "--home", str(fixture), "--root", "/", "--json")
        assert result.returncode == 2
        assert "unsafe root" in result.stderr


def test_rejects_broad_home_even_with_narrow_root(repo: Path) -> None:
    result = run_cli(repo, "scan", "--home", "/", "--root", "/tmp", "--json")
    assert result.returncode == 2
    assert "unsafe home" in result.stderr


def test_duplicate_roots_do_not_duplicate_candidates(repo: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="puremaccli-fixture-") as tmp:
        fixture = Path(tmp)
        make_dotnet_fixture(fixture)
        project = fixture / "SampleApp"
        result = run_cli(repo, "scan", "--home", str(fixture), "--root", str(fixture), "--root", str(project), "--json")
        assert result.returncode == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["candidateCount"] == 2


def test_install_agent_writes_valid_plist_for_xml_special_paths(repo: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="puremaccli home & fixture-") as tmp:
        fixture = Path(tmp)
        (fixture / "Projects").mkdir()
        result = run_cli(repo, "install-agent", "--home", str(fixture), "--root", str(fixture / "Projects"), "--json")
        assert result.returncode == 0, result.stderr
        plist = fixture / "Library" / "LaunchAgents" / "com.kovaforge.puremac.cleanup.plist"
        assert plist.exists()
        check = subprocess.run(["plutil", "-lint", str(plist)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert check.returncode == 0, check.stdout + check.stderr


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    cli = built_cli_path(repo)
    if not cli.exists():
        print(f"missing built CLI: {cli}", file=sys.stderr)
        return 2
    tests = [
        test_scan_finds_only_project_build_artifacts,
        test_dry_run_does_not_delete_and_execute_deletes,
        test_scan_and_clean_include_developer_package_caches,
        test_clean_short_circuits_when_already_above_threshold,
        test_manifest_is_valid_first_party_contract,
        test_rejects_broad_cleanup_roots,
        test_rejects_broad_home_even_with_narrow_root,
        test_duplicate_roots_do_not_duplicate_candidates,
        test_install_agent_writes_valid_plist_for_xml_special_paths,
    ]
    for test in tests:
        test(repo)
        print(f"PASS {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
