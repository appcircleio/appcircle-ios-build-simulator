# Appcircle _Xcodebuild for iOS Simulator_ component

Build your application for iOS Simulator in x86/arm64 architecture.

## Required Inputs

- `AC_REPOSITORY_DIR`: Repository Directory. Specifies the cloned repository directory.
- `AC_OUTPUT_DIR_PATH`: Output Directory Path. Specifies the path for outputs.
- `AC_SCHEME`: Scheme. Specifies the project scheme for build.
- `AC_PROJECT_PATH`: Project Path. Specifies the project path. For example : ./appcircle.xcodeproj
- `AC_COMPILER_INDEX_STORE_ENABLE`: Compiler Index Store Enable. You can disable the indexing during the build for faster build.

## Optional Inputs

- `AC_SIMULATOR_ARCH`: Architecture. Specifies the CPU architecture for the simulator build.
- `AC_SIMULATOR_NAME`: Simulator Name. Destination name of the simulator. Ex. `iPhone 14`. If you set a simulator name, the build will be installed into the given simulator. Please be aware setting the simulator name invalidates the `AC_SIMULATOR_ARCH` option.
- `AC_ARCHIVE_FLAGS`: Archive Flags. Specifies the extra xcodebuild flag. For example : -configuration DEBUG
- `AC_CONFIGURATION_NAME`: Configuration. The configuration to use. You can overwrite it with this option.

## Output Variables

- `AC_SIMULATOR_APP_PATH`: Simulator App Path. Simulator app path.
