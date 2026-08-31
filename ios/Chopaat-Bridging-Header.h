// Project bridging header — extends mob's bridging header with the
// mob_scene3d plugin's ObjC surface so the plugin's Swift viewport can
// instantiate the Filament view. Wired in ios/build.zig
// (-import-objc-header points here; mob's header and the plugin headers
// resolve via -Xcc -I paths).
#import "MobDemo-Bridging-Header.h"
// mob_scene3d plugin (manifest host_requirements): the viewport UIView +
// runtime seam, resolved via -Xcc -I<plugin>/priv/native/ios.
#import "MobScene3dRuntime.h"
#import "MobScene3dView.h"
