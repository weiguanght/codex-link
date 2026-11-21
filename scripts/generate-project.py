#!/usr/bin/env python3
"""Generate the Xcode project with vendored local Swift packages."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def identifier(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def main():
    ios_root = ROOT / 'ios'
    app_group = ios_root / 'CodexLink'
    latex = ios_root / 'Packages/iOS-LaTeX'
    files = sorted(app_group.glob('*.swift'))
    objc_files = sorted(app_group.glob('*.m'))
    objcxx_files = sorted(app_group.glob('*.mm'))
    header_files = sorted(app_group.glob('*.h'))
    objects = []
    def obj(name, value):
        objects.append(f'{identifier(name)} = {{ {value} }};')
    refs, builds, engine_refs = [], [], []
    for file in [*files, *objc_files, *objcxx_files]:
        key = file.name
        ref, build = 'ref:' + key, 'build:' + key
        file_type = {'.swift': 'sourcecode.swift', '.m': 'sourcecode.c.objc',
                     '.mm': 'sourcecode.cpp.objcpp'}[file.suffix]
        obj(ref, f'isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{file.name}"; sourceTree = "<group>";')
        obj(build, f'isa = PBXBuildFile; fileRef = {identifier(ref)};')
        refs.append(identifier(ref))
        builds.append(identifier(build))
    for file in sorted((latex / 'Swift').glob('*.swift')):
        relative = file.relative_to(latex).as_posix()
        ref, build = 'ref:iOS-LaTeX/' + relative, 'build:iOS-LaTeX/' + relative
        obj(ref, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{relative}"; sourceTree = "<group>";')
        obj(build, f'isa = PBXBuildFile; fileRef = {identifier(ref)};')
        engine_refs.append(identifier(ref))
        builds.append(identifier(build))
    for file in header_files:
        ref = 'ref:' + file.name
        obj(ref, f'isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = "{file.name}"; sourceTree = "<group>";')
        refs.append(identifier(ref))
    obj('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = CodexLink.app; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
    obj('assetsbuild', f'isa = PBXBuildFile; fileRef = {identifier("assets")};')
    refs.append(identifier('assets'))
    obj('syntaxassets', 'isa = PBXFileReference; lastKnownFileType = folder; path = SyntaxAssets; sourceTree = "<group>";')
    obj('syntaxassetsbuild', f'isa = PBXBuildFile; fileRef = {identifier("syntaxassets")};')
    refs.append(identifier('syntaxassets'))
    obj('latexfonts', 'isa = PBXFileReference; lastKnownFileType = folder; path = Fonts; sourceTree = "<group>";')
    obj('latexfontsbuild', f'isa = PBXBuildFile; fileRef = {identifier("latexfonts")};')
    engine_refs.append(identifier('latexfonts'))
    obj('latexnotices', 'isa = PBXFileReference; lastKnownFileType = folder; path = iOSLaTeXNotices; sourceTree = "<group>";')
    obj('latexnoticesbuild', f'isa = PBXBuildFile; fileRef = {identifier("latexnotices")};')
    engine_refs.append(identifier('latexnotices'))
    obj('sourcegroup', f'isa = PBXGroup; path = CodexLink; sourceTree = "<group>"; children = ({",".join(refs)},);')
    obj('latexgroup', f'isa = PBXGroup; name = "iOS-LaTeX"; path = "Packages/iOS-LaTeX"; sourceTree = SOURCE_ROOT; children = ({",".join(engine_refs)},);')
    obj('products', f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({identifier("app")},);')
    obj('main', f'isa = PBXGroup; sourceTree = "<group>"; children = ({identifier("sourcegroup")},{identifier("latexgroup")},{identifier("products")},);')
    obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
    obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({identifier("assetsbuild")},{identifier("syntaxassetsbuild")},{identifier("latexfontsbuild")},{identifier("latexnoticesbuild")},); runOnlyForDeploymentPostprocessing = 0;')
    obj('buildlatex', r'''isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647;
        name = "Build iOS-LaTeX Light"; files = (); alwaysOutOfDate = 1;
        outputPaths = ("$(DERIVED_FILE_DIR)/libios_latex.a",);
        runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash;
        shellScript = "bash \"$SRCROOT/../scripts/build-ios-latex.sh\"";
        showEnvVarsInLog = 0;''')
    packages = ['Runestone', 'RunestoneLanguageSupport']
    obj('editorpackage', 'isa = XCLocalSwiftPackageReference; relativePath = Packages/Runestone;')
    for product in packages:
        obj('packageproduct:' + product, f'isa = XCSwiftPackageProductDependency; productName = {product};')
        obj('packagebuild:' + product, f'isa = PBXBuildFile; productRef = {identifier("packageproduct:" + product)};')
    obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(identifier("packagebuild:" + p) for p in packages)},); runOnlyForDeploymentPostprocessing = 0;')
    for name in ('Debug', 'Release'):
        obj('project' + name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }};')
        obj('target' + name, f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{
            PRODUCT_NAME = CodexLink; PRODUCT_BUNDLE_IDENTIFIER = local.codex.link;
            INFOPLIST_FILE = CodexLink/Info.plist; GENERATE_INFOPLIST_FILE = NO;
            TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic;
            SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 16.0;
            SWIFT_INCLUDE_PATHS = ("$(inherited)","$(PROJECT_DIR)/Packages/iOS-LaTeX/Native/include",);
            LIBRARY_SEARCH_PATHS = ("$(inherited)","$(DERIVED_FILE_DIR)",);
            OTHER_LDFLAGS = "$(inherited) -lios_latex -framework Security";
            SWIFT_OPTIMIZATION_LEVEL = {"-Onone" if name == "Debug" else "-O"};
            ENABLE_USER_SCRIPT_SANDBOXING = NO;
            ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
            LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
        }};''')
    for group in ('project', 'target'):
        obj(group + 'configs', f'isa = XCConfigurationList; buildConfigurations = ({identifier(group + "Debug")},{identifier(group + "Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj('target', f'''isa = PBXNativeTarget; name = "codex-link"; productName = CodexLink;
        productType = "com.apple.product-type.application"; productReference = {identifier('app')};
        buildConfigurationList = {identifier('targetconfigs')};
        buildPhases = ({identifier('buildlatex')},{identifier('sources')},{identifier('frameworks')},{identifier('resources')},);
        buildRules = (); dependencies = (); packageProductDependencies = ({",".join(identifier("packageproduct:" + p) for p in packages)},);''')
    obj('uitestref', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeFlows.swift; sourceTree = "<group>";')
    obj('uitestbuild', f'isa = PBXBuildFile; fileRef = {identifier("uitestref")};')
    obj('uitestgroup', f'isa = PBXGroup; path = NativeUITests; sourceTree = "<group>"; children = ({identifier("uitestref")},);')
    obj('uitestproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = NativeUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('uitestsources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({identifier("uitestbuild")},); runOnlyForDeploymentPostprocessing = 0;')
    obj('uitestproxy', f'isa = PBXContainerItemProxy; containerPortal = {identifier("project")}; proxyType = 1; remoteGlobalIDString = {identifier("target")}; remoteInfo = "codex-link";')
    obj('uitestdependency', f'isa = PBXTargetDependency; target = {identifier("target")}; targetProxy = {identifier("uitestproxy")};')
    for name in ('Debug', 'Release'):
        obj('uitest' + name, f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{
            PRODUCT_NAME = NativeUITests; PRODUCT_BUNDLE_IDENTIFIER = local.codex.link.uitests;
            GENERATE_INFOPLIST_FILE = YES; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 16.0;
            TARGETED_DEVICE_FAMILY = "1,2"; TEST_TARGET_NAME = "codex-link";
        }};''')
    obj('uitestconfigs', f'isa = XCConfigurationList; buildConfigurations = ({identifier("uitestDebug")},{identifier("uitestRelease")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
    obj('uitesttarget', f'''isa = PBXNativeTarget; name = NativeUITests; productName = NativeUITests;
        productType = "com.apple.product-type.bundle.ui-testing"; productReference = {identifier("uitestproduct")};
        buildConfigurationList = {identifier("uitestconfigs")}; buildPhases = ({identifier("uitestsources")},);
        buildRules = (); dependencies = ({identifier("uitestdependency")},);''')
    # Include tests in navigation without adding test sources to the app target.
    objects = [line.replace(f'children = ({identifier("sourcegroup")},', f'children = ({identifier("uitestgroup")},{identifier("sourcegroup")},')
               .replace(f'children = ({identifier("app")},', f'children = ({identifier("uitestproduct")},{identifier("app")},') for line in objects]
    obj('project', f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 1520; }};
        buildConfigurationList = {identifier('projectconfigs')}; compatibilityVersion = "Xcode 14.0";
        developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN,en,Base,);
        mainGroup = {identifier('main')}; productRefGroup = {identifier('products')};
        projectDirPath = ""; projectRoot = ""; packageReferences = ({identifier('editorpackage')},); targets = ({identifier('target')},{identifier('uitesttarget')},);''')
    project = ROOT / 'ios/codex-link.xcodeproj'
    project.mkdir(exist_ok=True)
    (project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {identifier("project")}; }}\n')
    schemes = project / 'xcshareddata/xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    def buildable(key, product, name):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier(key)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:codex-link.xcodeproj"/>'
    app = buildable('target', 'CodexLink.app', 'codex-link')
    test = buildable('uitesttarget', 'NativeUITests.xctest', 'NativeUITests')
    (schemes / 'codex-link.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1520" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')


if __name__ == '__main__':
    main()
