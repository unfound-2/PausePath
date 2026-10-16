from pathlib import Path
root = Path(__file__).resolve().parents[1]
files = sorted(str(p.relative_to(root)) for p in (root/'PausePath').rglob('*.swift'))
def uid(n): return f'{n:024X}'
entries = []
def add(n, body): entries.append(f'{uid(n)} = {{ {body} }};')
refs = []
builds = []
for i,path in enumerate(files):
    ref, build = 100+i,200+i
    refs.append(uid(ref)); builds.append(uid(build))
    add(ref, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT;')
    add(build, f'isa = PBXBuildFile; fileRef = {uid(ref)};')
add(50, 'isa = PBXFileReference; explicitFileType = wrapper.application; path = PausePath.app; sourceTree = BUILT_PRODUCTS_DIR;')
add(51, 'isa = PBXFileReference; lastKnownFileType = text.xml; path = PausePath/Resources/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT;')
add(52, f'isa = PBXBuildFile; fileRef = {uid(51)};')
add(54, 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = PausePath/Resources/Assets.xcassets; sourceTree = SOURCE_ROOT;')
add(53, f'isa = PBXBuildFile; fileRef = {uid(54)};')
add(2, f'isa = PBXGroup; children = ({",".join(refs+[uid(51),uid(54),uid(3)])}); sourceTree = "<group>";')
add(3, f'isa = PBXGroup; children = ({uid(50)}); name = Products; sourceTree = "<group>";')
add(4, f'isa = PBXNativeTarget; buildConfigurationList = {uid(8)}; buildPhases = ({uid(5)},{uid(6)},{uid(7)}); buildRules = (); dependencies = (); name = PausePath; productName = PausePath; productReference = {uid(50)}; productType = "com.apple.product-type.application";')
add(5, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)}); runOnlyForDeploymentPostprocessing = 0;')
add(6, 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add(7, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid(52)},{uid(53)}); runOnlyForDeploymentPostprocessing = 0;')
for n,configs in [(8,[10,11]),(9,[12,13])]:
    add(n, f'isa = XCConfigurationList; buildConfigurations = ({",".join(uid(c) for c in configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for n,name in [(10,'Debug'),(11,'Release')]:
    add(n, f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
CODE_SIGN_STYLE = Automatic; CODE_SIGN_ENTITLEMENTS = PausePath/Resources/PausePath.entitlements;
PRODUCT_BUNDLE_IDENTIFIER = "com.unfound2.PausePath"; PRODUCT_NAME = "$(TARGET_NAME)";
INFOPLIST_FILE = PausePath/Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO;
IPHONEOS_DEPLOYMENT_TARGET = 17.0; TARGETED_DEVICE_FAMILY = "1,2";
SWIFT_VERSION = 5.0; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
SWIFT_OPTIMIZATION_LEVEL = "{'-Onone' if name == 'Debug' else '-O'}";
DEBUG_INFORMATION_FORMAT = "{'dwarf' if name == 'Debug' else 'dwarf-with-dsym'}";
}};''')
for n,name in [(12,'Debug'),(13,'Release')]:
    add(n, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ CLANG_ENABLE_MODULES = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{ "DEBUG" if name == "Debug" else ""}"; }};')
add(1,f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {uid(9)}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {uid(2)}; productRefGroup = {uid(3)}; projectDirPath = ""; projectRoot = ""; targets = ({uid(4)});')
(root/'PausePath.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(entries)+f'\n}}; rootObject = {uid(1)}; }}\n')
(root/'PausePath.xcodeproj/xcshareddata/xcschemes/PausePath.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(4)}" BuildableName="PausePath.app" BlueprintName="PausePath" ReferencedContainer="container:PausePath.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(4)}" BuildableName="PausePath.app" BlueprintName="PausePath" ReferencedContainer="container:PausePath.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
