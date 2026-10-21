"""Register Swift sources and the Live Activity extension without resetting signing.

Run after adding source files. Existing targets, capabilities, build settings,
team selection and app identity are preserved structurally.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess

root = Path(__file__).resolve().parents[1]
project = root / 'PausePath.xcodeproj/project.pbxproj'
raw = subprocess.check_output(['plutil','-convert','json','-o','-',str(project)])
pbx = json.loads(raw); objects = pbx['objects']
def uid(name): return hashlib.sha256(('pausepath-'+name).encode()).hexdigest()[:24].upper()
def add(name, value):
    key=uid(name); objects[key]=value; return key

def file_ref(path):
    for key,value in objects.items():
        if value.get('isa')=='PBXFileReference' and value.get('path')==path: return key
    return add('file:'+path,dict(isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path=path,sourceTree='SOURCE_ROOT'))
def build_ref(path, target): return add('build:'+target+':'+path,dict(isa='PBXBuildFile',fileRef=file_ref(path)))
project_object=objects[pbx['rootObject']]
app_id=next(key for key in project_object['targets'] if objects[key].get('name')=='PausePath')
app=objects[app_id]
main_group=objects[project_object['mainGroup']]
products=objects[project_object['productRefGroup']]
app_sources=next(objects[key] for key in app['buildPhases'] if objects[key]['isa']=='PBXSourcesBuildPhase')
# Include app and shared Swift sources, while keeping extension-only @main separate.
for path in sorted((root/'PausePath').rglob('*.swift')):
    relative=str(path.relative_to(root))
    reference=file_ref(relative)
    if reference not in main_group['children']: main_group['children'].append(reference)
    if '/Widgets/' in relative: continue
    existing=next((key for key in app_sources['files'] if objects[key].get('fileRef')==reference),None)
    if existing is None: app_sources['files'].append(build_ref(relative,'app'))

extension_id=uid('widget-target')
product=add('widget-product',dict(isa='PBXFileReference',explicitFileType='wrapper.app-extension',path='PausePathWidgets.appex',sourceTree='BUILT_PRODUCTS_DIR'))
if product not in products['children']: products['children'].append(product)
widget_paths=['PausePath/Widgets/PausePathWidgets.swift','PausePath/Shared/WalkActivityAttributes.swift','PausePath/Shared/PauseWalkIntent.swift']
sources=add('widget-sources',dict(isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=[build_ref(path,'widget') for path in widget_paths],runOnlyForDeploymentPostprocessing=0))
frameworks=add('widget-frameworks',dict(isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0))
resources=add('widget-resources',dict(isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0))
app_info=plistlib.loads((root/'PausePath/Resources/Info.plist').read_bytes())
configs=[]
for key in objects[app['buildConfigurationList']]['buildConfigurations']:
    current=objects[key]; settings=current['buildSettings']; name=current['name']
    widget_settings={
        'CODE_SIGN_STYLE': settings.get('CODE_SIGN_STYLE','Automatic'),
        'DEVELOPMENT_TEAM':settings.get('DEVELOPMENT_TEAM',''),
        'PRODUCT_BUNDLE_IDENTIFIER':settings['PRODUCT_BUNDLE_IDENTIFIER']+'.WalkWidgets',
        'PRODUCT_NAME':'PausePathWidgets','INFOPLIST_FILE':'PausePath/Widgets/Info.plist','GENERATE_INFOPLIST_FILE':'NO',
        'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator',
        'TARGETED_DEVICE_FAMILY':'1,2','SWIFT_VERSION':'5.0','APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited) PAUSEPATH_WIDGET',
        'CURRENT_PROJECT_VERSION':settings.get('CURRENT_PROJECT_VERSION',str(app_info.get('CFBundleVersion','2'))),
        'MARKETING_VERSION':settings.get('MARKETING_VERSION',app_info.get('CFBundleShortVersionString','1.0')),
        'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks',
        'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O',
        'DEBUG_INFORMATION_FORMAT':'dwarf' if name=='Debug' else 'dwarf-with-dsym',
    }
    configs.append(add('widget-config:'+name,dict(isa='XCBuildConfiguration',name=name,buildSettings=widget_settings)))
config_list=add('widget-configs',dict(isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release'))
objects[extension_id]=dict(isa='PBXNativeTarget',buildConfigurationList=config_list,buildPhases=[sources,frameworks,resources],buildRules=[],dependencies=[],name='PausePathWidgets',productName='PausePathWidgets',productReference=product,productType='com.apple.product-type.app-extension')
if extension_id not in project_object['targets']: project_object['targets'].append(extension_id)
proxy=add('widget-proxy',dict(isa='PBXContainerItemProxy',containerPortal=pbx['rootObject'],proxyType=1,remoteGlobalIDString=extension_id,remoteInfo='PausePathWidgets'))
dependency=add('widget-dependency',dict(isa='PBXTargetDependency',target=extension_id,targetProxy=proxy))
if dependency not in app['dependencies']: app['dependencies'].append(dependency)
embed_build=add('widget-embed-file',dict(isa='PBXBuildFile',fileRef=product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']}))
embed=add('widget-embed-phase',dict(isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=[embed_build],name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0))
if embed not in app['buildPhases']: app['buildPhases'].append(embed)
attrs=project_object.setdefault('attributes',{}).setdefault('TargetAttributes',{}).setdefault(app_id,{})
attrs.setdefault('SystemCapabilities',{})['com.apple.BackgroundModes']={'enabled':1}

def encode(value, depth=0):
    tab='\t'*depth
    if isinstance(value,dict): return '{\n'+''.join(tab+'\t'+json.dumps(str(k))+' = '+encode(v,depth+1)+';\n' for k,v in value.items())+tab+'}'
    if isinstance(value,list): return '(\n'+''.join(tab+'\t'+encode(v,depth+1)+',\n' for v in value)+tab+')'
    if isinstance(value,(int,float)): return str(value)
    return json.dumps(value,ensure_ascii=False)
project.write_text('// !$*UTF8*$!\n'+encode(pbx)+'\n')
print('Registered app sources and PausePathWidgets; preserved existing app settings.')
