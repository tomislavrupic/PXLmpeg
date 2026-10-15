#!/usr/bin/env python3
"""macOS development guard: sandboxed edits, independent copies, read-only probes.
No eval/exec, no shell interpolation, no original-media write operation.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / ".work/disposable-media"
SAFETY = ROOT / ".work/safety"
SANDBOX = Path("/usr/bin/sandbox-exec")
WORKSPACES = [ROOT, ROOT.parent / "Pixel Deck"]


def owned_directory(path):
    if path.resolve() != path.absolute() or not path.is_relative_to(ROOT):
        raise ValueError("Refusing symlinked/outside workspace directory")
    path.mkdir(parents=True,exist_ok=True)
    return path


def rule(action, operation, kind, paths):
    return "(" + action + " " + operation + " " + " ".join("("+kind+" "+json.dumps(str(p))+")" for p in paths) + ")"


def profile(writable, readable=None, denied_reads=(), tool_temporary=False):
    rules = ["(version 1)","(allow default)","(deny file-write*)",
             '(allow file-write* (literal "/dev/null"))']
    if tool_temporary:
        darwin_temp = Path(subprocess.check_output(["/usr/bin/getconf","DARWIN_USER_TEMP_DIR"],text=True).strip())
        bases = sorted({str(darwin_temp),str(darwin_temp.resolve())})
        # Apple tools ignore TMPDIR for xcrun caches / Foundation atomic saves.
        # Allow only named tool files, never the whole user temporary directory.
        names = ["swift", "swift-package", "swift-test", "swift_build", "swift-frontend", "swift_frontend", "swift-driver", "swift_driver", "swiftc", "xctest", "PXLmpegPackageTests",
                 "Pixel_Deck_PXL_Research", "Pixel Deck PXL Research", "PixelDeckPXLPlaybackChecks", "pxl-prores",
                 "xcodebuild", "XCBBuildService", "SWBBuildService", "swift-build", "swift-run", "Xcode",
                 "atomic-write-check", "atomic_write_check", "replacement-directory-check", "replacement_directory_check"]
        rules.append(rule("allow","file-write-create","literal",[darwin_temp/"TemporaryItems"]))
        patterns = [base+r"/swbuild[.]tmp[.][A-Za-z0-9]+($|/)" for base in bases]
        patterns += [base+r"/TemporaryDirectory[.][A-Za-z0-9]+($|/)" for base in bases]
        patterns += [base+r"/PXLmpeg-compiler-tests-[A-Fa-f0-9-]+($|/)" for base in bases]
        patterns += [base+r"/xcrun_db$" for base in bases]
        patterns += [base+r"/xcrun_db-[A-Za-z0-9]+$" for base in bases]
        patterns += [base+"/TemporaryItems/NSIRD_"+name+r"_[A-Za-z0-9]+($|/)" for base in bases for name in names]
        rules.append("(allow file-write* "+" ".join("(regex #"+json.dumps("^"+p)+")" for p in patterns)+")")
    if writable: rules.append(rule("allow","file-write*","subpath",writable))
    if readable is not None:
        rules += ["(deny file-read*)","(allow file-read-metadata)",rule("allow","file-read*","subpath",readable)]
    if denied_reads:
        rules.append(rule("deny","file-read*","literal",denied_reads))
        rules.append(rule("deny","file-write*","literal",denied_reads))
    return "\n".join(rules)


def launch(policy, command, workspace, temp, fixture=None):
    if not SANDBOX.is_file():
        raise RuntimeError("sandbox-exec unavailable; refusing to run unprotected")
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("PXL_"): env.pop(key)
    env.update(TMPDIR=str(temp)+"/", PYTHONDONTWRITEBYTECODE="1",
               PXL_SAFE_DEV_ACTIVE="probe" if fixture else "edit", xcrun_nocache="1",
               CLANG_MODULE_CACHE_PATH=str(workspace/".build/ModuleCache"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(workspace/".build/ModuleCache"))
    if fixture:
        receipt = json.loads((fixture/"manifest.json").read_text())
        env.update(PXL_DISPOSABLE_SOURCE=str(fixture/"input"/receipt["filename"]),
                   PXL_TEST_XAVC_SOURCE=str(fixture/"input"/receipt["filename"]),
                   PXL_DISPOSABLE_OUTPUT=str(fixture/"output"))
    if not command or command[0] == "--": raise ValueError("Missing executable")
    return subprocess.run([str(SANDBOX),"-p",policy,*command],cwd=workspace,env=env).returncode


def identity(st):
    return [st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns]


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(4*1024*1024): result.update(block)
    return result.hexdigest()


def copy_readonly(source, fixture):
    # Called only inside the stage sandbox, whose sole writable tree is fixture.
    source_fd = os.open(source,os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode): raise ValueError("Regular media file required")
        target = fixture/"input"/source.name
        target_fd = os.open(target,os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,0o600)
        sha = hashlib.sha256()
        with os.fdopen(target_fd,"wb") as destination:
            while block := os.read(source_fd,4*1024*1024):
                sha.update(block); destination.write(block)
            destination.flush(); os.fsync(destination.fileno())
        if identity(os.fstat(source_fd)) != identity(before) or identity(source.stat()) != identity(before):
            raise ValueError("Source changed while copying; fixture not admitted")
        if digest(target) != sha.hexdigest(): raise ValueError("Copy SHA-256 verification failed")
        os.chmod(target,0o444)
        copied = target.stat()
        if (copied.st_dev,copied.st_ino) == (before.st_dev,before.st_ino): raise ValueError("Copy is not independent")
        receipt = dict(schemaVersion=1, filename=source.name, source=str(source),
                       sourceIdentity=identity(before), copyIdentity=identity(copied),
                       sha256=sha.hexdigest(), copyMethod="independent-byte-copy",disposable=True)
        with (fixture/"manifest.json").open("x") as output: json.dump(receipt,output,indent=2)
    finally: os.close(source_fd)


def validate_fixture(value, full_hash=False):
    fixture = Path(value).absolute()
    if fixture.resolve() != fixture or fixture.parent != MEDIA or not fixture.is_dir():
        raise ValueError("Fixture must be a direct, unsymlinked disposable-media child")
    manifest = fixture/"manifest.json"
    if manifest.is_symlink(): raise ValueError("Symlinked receipt refused")
    receipt = json.loads(manifest.read_text())
    filename = receipt["filename"]
    if Path(filename).name != filename or not receipt.get("disposable") or receipt.get("schemaVersion") != 1:
        raise ValueError("Invalid disposable-copy receipt")
    target = fixture/"input"/filename
    if target.resolve() != target or identity(target.stat()) != receipt["copyIdentity"]:
        raise ValueError("Disposable input identity changed")
    if full_hash and digest(target) != receipt["sha256"]: raise ValueError("Disposable copy hash changed")
    if (fixture/"output").resolve() != fixture/"output": raise ValueError("Symlinked output refused")
    return fixture,receipt



def edit_policy(workspace,temp,extra_workspace=None):
    writable = [workspace,temp] + ([extra_workspace] if extra_workspace and extra_workspace != workspace else [])
    policy = profile(writable,tool_temporary=True)
    policy += "\n" + rule("allow","file-write*","subpath",[Path.home()/"Library/Caches/org.swift.swiftpm"])
    policy += "\n" + rule("deny","file-write*","subpath",[MEDIA])
    originals = []
    for manifest in MEDIA.glob("*/manifest.json"):
        originals.append(json.loads(manifest.read_text())["source"])
    if originals:
        policy += "\n" + rule("deny","file-write*","literal",originals)
        policy += "\n" + rule("deny","file-read*","literal",originals)
    policy += "\n" + rule("deny","file-read*","subpath",["/Volumes"])
    reports = [p for p in MEDIA.glob("*/output/*.json") if not p.is_symlink() and p.resolve() == p]
    report_exclusions = " ".join("(require-not (literal "+json.dumps(str(p))+"))" for p in reports)
    policy += "\n(deny file-read* (require-all (subpath "+json.dumps(str(MEDIA))+") "+report_exclusions+"))"
    ancestors = set()
    for protected in [MEDIA,*map(Path,originals)]:
        for ancestor in [protected,*protected.parents]:
            ancestors.add(ancestor)
    # Rename/remove of an ancestor must not move protected paths out of policy.
    if ancestors: policy += "\n" + rule("deny","file-write-unlink","literal",sorted(ancestors))
    return policy

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode",required=True)
    stage = sub.add_parser("stage"); stage.add_argument("source")
    copy = sub.add_parser("_copy"); copy.add_argument("source"); copy.add_argument("fixture")
    verify = sub.add_parser("verify"); verify.add_argument("fixture")
    for name in ["edit","probe"]:
        command = sub.add_parser(name)
        command.add_argument("--workspace",default=str(ROOT))
        if name == "edit": command.add_argument("--with-pxl-package",action="store_true")
        if name == "probe": command.add_argument("--fixture",required=True)
        command.add_argument("command",nargs=argparse.REMAINDER)
    args = parser.parse_args()
    owned_directory(SAFETY); owned_directory(MEDIA)
    if args.mode == "_copy":
        fixture = Path(args.fixture).absolute()
        if fixture.resolve() != fixture or fixture.parent != MEDIA: raise ValueError("Invalid copy staging directory")
        copy_readonly(Path(args.source),fixture); return 0
    if args.mode == "stage":
        source = Path(args.source).absolute()
        if source.resolve() != source: raise ValueError("Use a real, non-symlink source path")
        st = source.stat()
        if not stat.S_ISREG(st.st_mode): raise ValueError("Regular file required")
        if source.is_relative_to(MEDIA): raise ValueError("Already-disposable input refused as original")
        if shutil.disk_usage(ROOT).free < st.st_size+1024*1024*1024: raise ValueError("Insufficient space for independent copy")
        fixture = owned_directory(MEDIA/str(uuid.uuid4()))
        owned_directory(fixture/"input"); owned_directory(fixture/"output"); temp = owned_directory(fixture/"output/tmp")
        status = launch(profile([fixture]),[sys.executable,str(Path(__file__).resolve()),"_copy",str(source),str(fixture)],ROOT,temp)
        if status: return status
        validate_fixture(fixture,full_hash=True)
        print(fixture); return 0
    if args.mode == "verify":
        fixture,_ = validate_fixture(args.fixture,full_hash=True)
        print("Verified disposable copy SHA-256:",fixture); return 0
    workspace = Path(args.workspace).absolute()
    if workspace.resolve() != workspace or workspace not in WORKSPACES: raise ValueError("Workspace is not in the explicit development allowlist")
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if args.mode == "edit":
        temp = owned_directory(SAFETY/"tmp")
        return launch(edit_policy(workspace,temp,ROOT if args.with_pxl_package else None),command,workspace,temp)
    fixture,receipt = validate_fixture(args.fixture)
    output = fixture/"output"; temp = owned_directory(output/"tmp")
    # Explicitly deny every staged original even if it falls inside a runtime read tree.
    originals = [receipt["source"]]
    for manifest in MEDIA.glob("*/manifest.json"):
        originals.append(json.loads(manifest.read_text())["source"])
    policy = profile([output],denied_reads=originals,tool_temporary=True)
    # Default-deny reads prevents process bootstrap on this macOS. Protect media
    # trees explicitly while preserving OS runtime reads; writes remain deny-all
    # except this fixture's output directory.
    media_locations = ["/Volumes",Path.home()/"Desktop",Path.home()/"Downloads",
                       Path.home()/"Pictures",Path.home()/"Movies",Path.home()/"Music"]
    policy += "\n" + rule("deny","file-read*","subpath",media_locations)
    exclusions = " ".join("(require-not (subpath "+json.dumps(str(w)) +"))" for w in WORKSPACES)
    policy += "\n(deny file-read* (require-all (subpath "+json.dumps(str(Path.home()/"Documents"))+ ") "+exclusions+"))"
    policy += "\n(deny file-read* (require-all (subpath "+json.dumps(str(MEDIA))+") (require-not (subpath "+json.dumps(str(fixture))+"))))"
    return launch(policy,command,workspace,temp,fixture)

if __name__ == "__main__":
    try: sys.exit(main())
    except (OSError,ValueError,KeyError,RuntimeError) as error:
        print("safe-dev: "+str(error),file=sys.stderr); sys.exit(2)
