#!/usr/bin/env python3
"""Add PatchSandboxSB Run Script phase to project.pbxproj BEFORE the Embed phase."""
import sys
import uuid

PROJECT = "ios/BiliPaiNative/BiliPaiNative.xcodeproj/project.pbxproj"


def gen_id():
    return uuid.uuid4().hex.upper()[:24]


def do_patch(path):
    with open(path) as f:
        content = f.read()

    if 'PatchSandboxSB' in content:
        print(f"[patch_sandbox] Already patched: {path}")
        return

    phase_id    = gen_id()
    file_ref_id = gen_id()
    build_id    = gen_id()

    # PBXFileReference for the external shell script file
    file_ref = (
        f'\t\t{file_ref_id} /* PatchSandboxSB.sh */ = {{isa = PBXFileReference; '
        f'fileEncoding = 4; lastKnownFileType = text.script.sh; '
        f'name = PatchSandboxSB.sh; path = PatchSandboxSB.sh; sourceTree = "<group>"; }};\n'
    )

    # PBXBuildFile (required: must appear in a Sources build phase for pbxproj validity)
    build_file = (
        f'\t\t{build_id} /* PatchSandboxSB.sh in Sources */ = {{isa = PBXBuildFile; '
        f'fileRef = {file_ref_id} /* PatchSandboxSB.sh */; }};\n'
    )

    # PBXShellScriptBuildPhase
    # shellPath = /bin/sh  +  shellScript = "...; source ./script.sh" avoids
    # embedding any complex string content in the pbxproj.
    shell_phase = (
        f'\n/* Begin PBXShellScriptBuildPhase section */\n'
        f'\t\t{phase_id} /* PatchSandboxSB */ = {{isa = PBXShellScriptBuildPhase;\n'
        f'\t\t\tbuildActionMask = 2147483647;\n'
        f'\t\t\tfiles = (\n'
        f'\t\t\t);\n'
        f'\t\t\tinputFileListPaths = (\n'
        f'\t\t\t);\n'
        f'\t\t\tinputPaths = (\n'
        f'\t\t\t);\n'
        f'\t\t\tname = PatchSandboxSB;\n'
        f'\t\t\toutputFileListPaths = (\n'
        f'\t\t\t);\n'
        f'\t\t\toutputPaths = (\n'
        f'\t\t\t);\n'
        f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
        f'\t\t\tshellPath = /bin/sh;\n'
        f'\t\t\tshellScript = ". \\"${{PROJECT_DIR}}/PatchSandboxSB.sh\\"";\n'
        f'\t\t}};\n'
        f'/* End PBXShellScriptBuildPhase section */\n'
    )

    content = content.replace(
        '/* End PBXFileReference section */',
        file_ref + '/* End PBXFileReference section */',
    )
    content = content.replace(
        '/* End PBXBuildFile section */',
        build_file + '/* End PBXBuildFile section */',
    )
    content = content.replace(
        'rootObject = 100000000000000000000601 /* Project object */;',
        shell_phase + '\trootObject = 100000000000000000000601 /* Project object */;',
    )
    content = content.replace(
        '100000000000000000000701 /* Sources */,',
        '100000000000000000000701 /* Sources */,\n\t\t\t\t' + phase_id + ' /* PatchSandboxSB */,',
    )

    with open(path, 'w') as f:
        f.write(content)

    print(f"[patch_sandbox] Patched {path}")


if __name__ == "__main__":
    do_patch(sys.argv[1] if len(sys.argv) > 1 else PROJECT)