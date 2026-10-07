#!/usr/bin/env python3
"""Regenerate the three native Xcode targets without installing project generators."""
from pathlib import Path
import hashlib, json

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
def arr(values): return '(' + ', '.join(values) + ')'
def add(name, isa, fields):
    key = ident(name)
    objects[key] = '{ isa = ' + isa + '; ' + ' '.join(f'{k} = {v};' for k,v in fields.items()) + ' }'
    return key
def reference(path, kind=None):
    p=Path(path)
    kind=kind or {'.swift':'sourcecode.swift','.m':'sourcecode.c.objc','.h':'sourcecode.c.h','.js':'sourcecode.javascript','.json':'text.json','.plist':'text.plist.xml','.entitlements':'text.plist.entitlements','.icon':'folder.iconcomposer.icon','.icns':'image.icns','.png':'image.png','.md':'text'}.get(p.suffix,'file')
    return add('file:'+path,'PBXFileReference',{'lastKnownFileType':q(kind),'path':q(path),'sourceTree':q('<group>')})

package=add('package','XCLocalSwiftPackageReference',{'relativePath':q('.')})
target_ids={name:ident('target:'+name) for name in ['SiftX','SiftX Safari Extension','SiftX Media Probe','SiftXDownloadTests']}
products=[]; groups=[]
for name, directory, bundle, plist, entitlements, product_type in [
    ('SiftX','App','com.siftx.SiftX','Config/App-Info.plist','Config/App.entitlements','com.apple.product-type.application'),
    ('SiftX Safari Extension','SafariExtension','com.siftx.SiftX.SafariExtension','SafariExtension/Info.plist','SafariExtension/SafariExtension.entitlements','com.apple.product-type.app-extension'),
    ('SiftX Media Probe','MediaProbe','com.siftx.SiftX.MediaProbe','MediaProbe/Info.plist','MediaProbe/MediaProbe.entitlements','com.apple.product-type.app-extension'),
    ('SiftXDownloadTests','Tests/DownloadTests','com.siftx.SiftX.DownloadTests',None,None,'com.apple.product-type.bundle.unit-test')
]:
    source_paths=sorted(str(p.relative_to(ROOT)) for p in (ROOT/directory).rglob('*.swift'))
    if name=='SiftX': source_paths+=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'App').rglob('*.m'))
    if name=='SiftXDownloadTests': source_paths += sorted(str(p.relative_to(ROOT)) for p in (ROOT/'App/Downloads').rglob('*.swift'))
    resource_paths=[]
    if name=='SiftX':
        resource_root = ROOT/'App/Resources'
        icons = sorted(resource_root.glob('*.icon'))
        tool_root = resource_root / 'YouTubeTools'
        resource_paths = [str(p.relative_to(ROOT)) for p in resource_root.rglob('*')
                          if p.is_file() and not any(parent.suffix == '.icon' for parent in p.parents)
                          and tool_root not in p.parents
                          and not (icons and p.name == 'AppIcon.icns')]
        resource_paths += [str(p.relative_to(ROOT)) for p in icons]
        if tool_root.exists(): resource_paths.append(str(tool_root.relative_to(ROOT)))
        resource_paths.append('SafariExtension/ToolbarSymbol.png')
    elif name=='SiftX Media Probe': resource_paths=[str(p.relative_to(ROOT)) for p in (ROOT/'MediaProbe/Resources').rglob('*') if p.is_file()]
    elif name=='SiftX Safari Extension': resource_paths=[str(p.relative_to(ROOT)) for p in (ROOT/'SafariExtension').rglob('*') if p.is_file() and p.suffix in ['.js','.png','.svg','.pdf']]
    refs=[]; sources=[]; resources=[]
    for path, phase in [(p,sources) for p in source_paths]+[(p,resources) for p in resource_paths]:
        ref=reference(path, 'folder' if path == 'App/Resources/YouTubeTools' else None)
        if not ((name=='SiftXDownloadTests' and path.startswith('App/'))
                or (name=='SiftX' and path=='SafariExtension/ToolbarSymbol.png')): refs.append(ref)
        phase.append(add(f'build:{name}:{path}','PBXBuildFile',{'fileRef':ref}))
    for path in [plist,entitlements]:
        if path: refs.append(reference(path))
    groups.append(add('group:'+name,'PBXGroup',{'children':arr(refs),'name':q(name),'sourceTree':q('<group>')}))
    product_name='SiftX.app' if name=='SiftX' else ('SiftXDownloadTests.xctest' if name=='SiftXDownloadTests' else ('SiftXSafariExtension.appex' if name=='SiftX Safari Extension' else 'SiftXMediaProbe.appex'))
    product=add('product:'+name,'PBXFileReference',{'explicitFileType':q('wrapper.application' if name=='SiftX' else ('wrapper.cfbundle' if name=='SiftXDownloadTests' else 'wrapper.app-extension')),'includeInIndex':'0','path':q(product_name),'sourceTree':q('BUILT_PRODUCTS_DIR')}); products.append(product)
    dependency=add('core:'+name,'XCSwiftPackageProductDependency',{'package':package,'productName':q('SiftXCore')})
    framework=add('corebuild:'+name,'PBXBuildFile',{'productRef':dependency})
    phases=[]
    for phase,isa,files in [('sources','PBXSourcesBuildPhase',sources),('frameworks','PBXFrameworksBuildPhase',[framework]),('resources','PBXResourcesBuildPhase',resources)]:
        phases.append(add(f'phase:{name}:{phase}',isa,{'buildActionMask':'2147483647','files':arr(files),'runOnlyForDeploymentPostprocessing':'0'}))
    deps=[]
    if name=='SiftX':
        embeds=[]
        for extension in ['SiftX Safari Extension','SiftX Media Probe']:
            proxy=add('proxy:'+extension,'PBXContainerItemProxy',{'containerPortal':ident('project'),'proxyType':'1','remoteGlobalIDString':target_ids[extension],'remoteInfo':q(extension)})
            deps.append(add('dependency:'+extension,'PBXTargetDependency',{'target':target_ids[extension],'targetProxy':proxy}))
            embeds.append(add('embed:'+extension,'PBXBuildFile',{'fileRef':ident('product:'+extension),'settings':'{ ATTRIBUTES = (RemoveHeadersOnCopy, CodeSignOnCopy); }'}))
        phases.append(add('embedphase','PBXCopyFilesBuildPhase',{'buildActionMask':'2147483647','dstPath':q(''),'dstSubfolderSpec':'13','files':arr(embeds),'name':q('Embed App Extensions'),'runOnlyForDeploymentPostprocessing':'0'}))
        phases.append(add('ffmpegsign','PBXShellScriptBuildPhase',{'buildActionMask':'2147483647','files':'()','inputPaths':arr([q('$(SRCROOT)/App/Resources/ffmpeg')]),'outputPaths':'()', 'alwaysOutOfDate':'1','shellPath':q('/bin/sh'),'shellScript':q('if [ "${CODE_SIGNING_ALLOWED}" = "YES" ]; then /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --entitlements "${SRCROOT}/Config/MediaTool.entitlements" "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ffmpeg"; fi\n'),'name':q('Sign local media processor')}))
        phases.append(add('youtubetoolsign','PBXShellScriptBuildPhase',{'buildActionMask':'2147483647','files':'()','inputPaths':arr([q('$(SRCROOT)/Scripts/sign_youtube_tools.py')]),'outputPaths':'()', 'alwaysOutOfDate':'1','shellPath':q('/bin/sh'),'shellScript':q('python3 "${SRCROOT}/Scripts/sign_youtube_tools.py"\n'),'name':q('Sign media parser tools')}))
    configurations=[]
    for configuration in ['Debug','Release']:
        settings={'PRODUCT_NAME':q(product_name.rsplit('.',1)[0]),'PRODUCT_BUNDLE_IDENTIFIER':q(bundle),'SWIFT_VERSION':'6.0','ARCHS':'arm64','ONLY_ACTIVE_ARCH':'YES','MACOSX_DEPLOYMENT_TARGET':'14.0','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'P57SZ9Z7G2','CODE_SIGN_IDENTITY':q('Apple Development'),'COMBINE_HIDPI_IMAGES':'YES','SWIFT_EMIT_LOC_STRINGS':'YES','SWIFT_ACTIVE_COMPILATION_CONDITIONS':q('DEBUG' if configuration=='Debug' else ''),'ENABLE_USER_SCRIPT_SANDBOXING':'NO','GENERATE_INFOPLIST_FILE':'NO' if plist else 'YES','LD_RUNPATH_SEARCH_PATHS':q('$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks'),'SWIFT_OPTIMIZATION_LEVEL':q('-Onone' if configuration=='Debug' else '-O'),'ENABLE_TESTABILITY':'YES' if configuration=='Debug' else 'NO'}
        if plist: settings['INFOPLIST_FILE']=q(plist)
        settings['CONFIGURATION_BUILD_DIR']=q('$(SRCROOT)/Build')
        # SPM package products are built into DerivedData products dir, not CONFIGURATION_BUILD_DIR;
        # without this the explicit-module scanner cannot resolve SiftXCore in a clean build.
        settings['SWIFT_INCLUDE_PATHS']=q('$(inherited) $(BUILD_DIR)/$(CONFIGURATION)')
        settings['LIBRARY_SEARCH_PATHS']=q('$(inherited) $(BUILD_DIR)/$(CONFIGURATION)')
        if name=='SiftX':
            # Preserve audited third-party executable bytes during resource copying.
            settings['COPY_PHASE_STRIP']='NO'
            settings['SWIFT_OBJC_BRIDGING_HEADER']=q('Config/SiftX-Bridging-Header.h')
            settings['ASSETCATALOG_COMPILER_APPICON_NAME']=q('AppIcon')
        if entitlements: settings['CODE_SIGN_ENTITLEMENTS']=q(entitlements)
        if name!='SiftX': settings['SKIP_INSTALL']='YES'
        if 'Extension' in name or name=='SiftX Media Probe': settings['APPLICATION_EXTENSION_API_ONLY']='YES'
        if name=='SiftXDownloadTests': settings['CODE_SIGNING_ALLOWED']='NO'
        configurations.append(add('config:'+name+configuration,'XCBuildConfiguration',{'buildSettings':'{ '+ ' '.join(f'{k} = {v};' for k,v in settings.items())+' }','name':q(configuration)}))
    configlist=add('configlist:'+name,'XCConfigurationList',{'buildConfigurations':arr(configurations),'defaultConfigurationIsVisible':'0','defaultConfigurationName':q('Debug')})
    add('target:'+name,'PBXNativeTarget',{'buildConfigurationList':configlist,'buildPhases':arr(phases),'buildRules':'()','dependencies':arr(deps),'name':q(name),'packageProductDependencies':arr([dependency]),'productName':q(name),'productReference':product,'productType':q(product_type)})

products_group=add('products','PBXGroup',{'children':arr(products),'name':q('Products'),'sourceTree':q('<group>')})
main_group=add('main','PBXGroup',{'children':arr(groups+[products_group]),'sourceTree':q('<group>')})
configs=[]
for name in ['Debug','Release']:
    configs.append(add('projectconfig:'+name,'XCBuildConfiguration',{'name':q(name),'buildSettings':'{ SDKROOT = macosx; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; GCC_C_LANGUAGE_STANDARD = gnu17; SWIFT_STRICT_CONCURRENCY = complete; DEBUG_INFORMATION_FORMAT = dwarf; }'}))
project_configs=add('projectconfigs','XCConfigurationList',{'buildConfigurations':arr(configs),'defaultConfigurationIsVisible':'0','defaultConfigurationName':q('Debug')})
project=add('project','PBXProject',{'attributes':'{ LastUpgradeCheck = 2700; BuildIndependentTargetsInParallel = YES; }','buildConfigurationList':project_configs,'compatibilityVersion':q('Xcode 14.0'),'developmentRegion':'en','hasScannedForEncodings':'0','knownRegions':'(en, Base)','mainGroup':main_group,'packageReferences':arr([package]),'productRefGroup':products_group,'projectDirPath':q(''),'projectRoot':q(''),'targets':arr(target_ids.values())})
directory=ROOT/'SiftX.xcodeproj'; directory.mkdir(exist_ok=True)
(directory/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'+'\n'.join(f'{k} = {v};' for k,v in objects.items())+f'\n}}; rootObject = {project}; }}\n')
schemes=directory/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
def build_ref(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[name]}" BuildableName="{ "SiftX.app" if name=="SiftX" else "SiftXDownloadTests.xctest" }" BlueprintName="{name}" ReferencedContainer="container:SiftX.xcodeproj"/>'
(schemes/'SiftX.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{build_ref('SiftX')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{build_ref('SiftXDownloadTests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref('SiftX')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref('SiftX')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated SiftX.xcodeproj (app, two extensions, download integration tests).')
