/// The app's version, stamped at build time by version.sh (`git describe`,
/// the same as the robot's); "dev" in `flutter run` without it.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
