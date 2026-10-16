#!/usr/bin/env python3
# coding: utf-8
"""Generate a deterministic Xcode project using only the Python standard library."""
import hashlib, json, pathlib
root=pathlib.Path(__file__).resolve().parents[1]
ios=root/'ios'
objects={}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(keyname, isa, **values):
    key=uid(keyname);objects[key]={'isa':isa,**values};return key
def ref(name,path,kind):return obj(name,'PBXFileReference',lastKnownFileType=kind,path=path,sourceTree='<group>')
config=ref('config','Config.xcconfig','text.xcconfig')
source_refs=[];source_build=[]
for p in sorted((ios/'AlphaRemote').glob('*.swift')):
    r=ref(p.name,'AlphaRemote/'+p.name,'sourcecode.swift');source_refs.append(r);source_build.append(obj('build-'+p.name,'PBXBuildFile',fileRef=r))
resources=[]
for path,kind in [('AlphaRemote/Assets.xcassets','folder.assetcatalog'),('AlphaRemote/ThirdParty.txt','text')]:
    r=ref(path,path,kind);source_refs.append(r);resources.append(obj('build-'+path,'PBXBuildFile',fileRef=r))
source_refs += [ref('plist','AlphaRemote/Info.plist','text.plist.xml'),ref('header','AlphaRemote/CameraCore.h','sourcecode.c.h')]
testfile=ref('smoketest','AlphaRemoteUITests/SmokeTests.swift','sourcecode.swift')
testbuild=obj('build-test','PBXBuildFile',fileRef=testfile)
product=obj('app-product','PBXFileReference',explicitFileType='wrapper.application',path='AlphaRemote.app',sourceTree='BUILT_PRODUCTS_DIR')
testproduct=obj('test-product','PBXFileReference',explicitFileType='wrapper.cfbundle',path='AlphaRemoteUITests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
products=obj('products','PBXGroup',children=[product,testproduct],name='Products',sourceTree='<group>')
main=obj('group','PBXGroup',children=source_refs+[testfile,config,products],sourceTree='<group>')
shell=obj('core-phase','PBXShellScriptBuildPhase',buildActionMask=2147483647,files=[],inputPaths=[],outputPaths=[],runOnlyForDeploymentPostprocessing=0,alwaysOutOfDate=1,shellPath='/bin/bash',shellScript='set -euo pipefail\nexport PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"\nARCH="${CURRENT_ARCH:-arm64}"\nif [ "$ARCH" = "undefined_arch" ]; then ARCH="${NATIVE_ARCH_ACTUAL:-arm64}"; fi\n"$SRCROOT/../scripts/build-core.sh" "$PLATFORM_NAME" "$ARCH"\n',name='Build native camera core')
def phase(name,isa,files):return obj(name,isa,buildActionMask=2147483647,files=files,runOnlyForDeploymentPostprocessing=0)
sources=phase('sources','PBXSourcesBuildPhase',source_build)
res=phase('resources','PBXResourcesBuildPhase',resources)
frameworks=phase('frameworks','PBXFrameworksBuildPhase',[])
testsources=phase('test-sources','PBXSourcesBuildPhase',[testbuild])
testframeworks=phase('test-frameworks','PBXFrameworksBuildPhase',[])
def configs(name,settings,base=False):
    ids=[]
    for mode in ('Debug','Release'):
        s=dict(settings)
        s['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if mode=='Debug' else '-O'
        s['DEBUG_INFORMATION_FORMAT']='dwarf' if mode=='Debug' else 'dwarf-with-dsym'
        if mode=='Debug':s['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
        values=dict(buildSettings=s,name=mode)
        if base:values['baseConfigurationReference']=config
        ids.append(obj(name+'-'+mode,'XCBuildConfiguration',**values))
    return obj(name+'-configs','XCConfigurationList',buildConfigurations=ids,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
projectconfig=configs('project',{'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'26.0','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'NO','ONLY_ACTIVE_ARCH':'YES','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','TARGETED_DEVICE_FAMILY':'1,2'})
appconfig=configs('app',{'PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'AlphaRemote/Info.plist','SWIFT_OBJC_BRIDGING_HEADER':'AlphaRemote/CameraCore.h','LIBRARY_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/../build/core/$(PLATFORM_NAME)-$(CURRENT_ARCH)'],'OTHER_LDFLAGS':['$(inherited)','-lCameraCore','-lresolv'],'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','CODE_SIGN_STYLE':'Automatic','ENABLE_BITCODE':'NO','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks']},True)
app=obj('app','PBXNativeTarget',buildConfigurationList=appconfig,buildPhases=[shell,sources,frameworks,res],buildRules=[],dependencies=[],name='AlphaRemote',productName='AlphaRemote',productReference=product,productType='com.apple.product-type.application')
proxy=obj('proxy','PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=app,remoteInfo='AlphaRemote')
dep=obj('dependency','PBXTargetDependency',target=app,targetProxy=proxy)
testconfig=configs('test',{'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'com.classundefined.alpha6700.uitests','GENERATE_INFOPLIST_FILE':'YES','CODE_SIGN_STYLE':'Automatic','TEST_TARGET_NAME':'AlphaRemote','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks']},True)
test=obj('test','PBXNativeTarget',buildConfigurationList=testconfig,buildPhases=[testsources,testframeworks],buildRules=[],dependencies=[dep],name='AlphaRemoteUITests',productName='AlphaRemoteUITests',productReference=testproduct,productType='com.apple.product-type.bundle.ui-testing')
project=obj('project','PBXProject',attributes={'LastUpgradeCheck':'2640','BuildIndependentTargetsInParallel':'YES','TargetAttributes':{app:{'CreatedOnToolsVersion':'26.4'},test:{'CreatedOnToolsVersion':'26.4','TestTargetID':app}}},buildConfigurationList=projectconfig,compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',hasScannedForEncodings=0,knownRegions=['en','zh-Hans','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app,test])
def fmt(v,depth=0):
    if isinstance(v,dict):return '{\n'+''.join('\t'*(depth+1)+json.dumps(str(k))+ ' = '+fmt(x,depth+1)+';\n' for k,x in v.items())+'\t'*depth+'}'
    if isinstance(v,list):return '('+', '.join(fmt(x,depth) for x in v)+')'
    if isinstance(v,int):return str(v)
    return json.dumps(v,ensure_ascii=False)
(ios/'AlphaRemote.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+fmt({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
def buildable(id,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{id}" BuildableName="{name}.{"app" if name=="AlphaRemote" else "xctest"}" BlueprintName="{name}" ReferencedContainer="container:AlphaRemote.xcodeproj"/>'
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2640" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable(app,'AlphaRemote')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable(test,'AlphaRemoteUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable(app,'AlphaRemote')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable(app,'AlphaRemote')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(ios/'AlphaRemote.xcodeproj/xcshareddata/xcschemes/AlphaRemote.xcscheme').write_text(scheme)
