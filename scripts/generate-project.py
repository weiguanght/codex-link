#!/usr/bin/env python3
"""Generate a dependency-free Xcode project (no CocoaPods / xcodegen)."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def identifier(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def main():
    files = sorted((ROOT / 'ios/CodexLink').glob('*.swift'))
    objects = []
    def obj(name, value):
        objects.append(f'{identifier(name)} = {{ {value} }};')
    refs, builds = [], []
    for file in files:
        ref, build = 'ref:' + file.name, 'build:' + file.name
        obj(ref, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{file.name}"; sourceTree = "<group>";')
        obj(build, f'isa = PBXBuildFile; fileRef = {identifier(ref)};')
        refs.append(identifier(ref))
        builds.append(identifier(build))
    obj('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = CodexLink.app; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
    obj('assetsbuild', f'isa = PBXBuildFile; fileRef = {identifier("assets")};')
    refs.append(identifier('assets'))
    obj('sourcegroup', f'isa = PBXGroup; path = CodexLink; sourceTree = "<group>"; children = ({",".join(refs)},);')
    obj('products', f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({identifier("app")},);')
    obj('main', f'isa = PBXGroup; sourceTree = "<group>"; children = ({identifier("sourcegroup")},{identifier("products")},);')
    obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
    obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({identifier("assetsbuild")},); runOnlyForDeploymentPostprocessing = 0;')
    obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    for name in ('Debug', 'Release'):
        obj('project' + name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }};')
        obj('target' + name, f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{
            PRODUCT_NAME = CodexLink; PRODUCT_BUNDLE_IDENTIFIER = local.codex.link;
            INFOPLIST_FILE = CodexLink/Info.plist; GENERATE_INFOPLIST_FILE = NO;
            TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic;
            SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 16.0;
            SWIFT_OPTIMIZATION_LEVEL = {"-Onone" if name == "Debug" else "-O"};
            ENABLE_USER_SCRIPT_SANDBOXING = YES;
            ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
            LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
        }};''')
    for group in ('project', 'target'):
        obj(group + 'configs', f'isa = XCConfigurationList; buildConfigurations = ({identifier(group + "Debug")},{identifier(group + "Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj('target', f'''isa = PBXNativeTarget; name = "codex-link"; productName = CodexLink;
        productType = "com.apple.product-type.application"; productReference = {identifier('app')};
        buildConfigurationList = {identifier('targetconfigs')};
        buildPhases = ({identifier('sources')},{identifier('frameworks')},{identifier('resources')},);
        buildRules = (); dependencies = ();''')
    obj('project', f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 1520; }};
        buildConfigurationList = {identifier('projectconfigs')}; compatibilityVersion = "Xcode 14.0";
        developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN,en,Base,);
        mainGroup = {identifier('main')}; productRefGroup = {identifier('products')};
        projectDirPath = ""; projectRoot = ""; targets = ({identifier('target')},);''')
    project = ROOT / 'ios/codex-link.xcodeproj'
    project.mkdir(exist_ok=True)
    (project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {identifier("project")}; }}\n')


if __name__ == '__main__':
    main()
