# Appcircle Xcodebuild For Simulator

This step builds your application for the iOS Simulator in x86 architecture which is required for the Preview on Device (Appcircle simulator) feature. This step creates an unsigned xarchive file.

Similar to the Xcode Archive & Export step, this step also uses main configuration parameters like project path, scheme and Xcode version and additionally use parameters like -sdk iphonesimulator, -destination generic/platform=iOS and PLATFORM_NAME=iphonesimulator.

This will output an xarchive file and lets you use the build on the virtual devices like simulators.

Required Input Variables
- `$AC_SCHEME`: Specifies the project scheme for build.
- `$AC_PROJECT_PATH`: Specifies the project path. For example : ./appcircle.xcodeproj.


Optional Input Variables
- `$AC_REPOSITORY_DIR`: Specifies the cloned repository directory.
- `$AC_ARCHIVE_FLAGS`: Specifies the extra xcodebuild flag. For example : -configuration DEBUG
- `$AC_CONFIGURATION_NAME`: The configuration to use. You can overwrite it with this option.
- `$AC_COMPILER_INDEX_STORE_ENABLE`: You can disable the indexing during the build for faster build.

Output Variables
- `$AC_SIMULATOR_ARCHIVE_PATH`: Simulator archive path.
