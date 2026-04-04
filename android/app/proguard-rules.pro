## Flutter-specific ProGuard rules

# Keep Flutter wrapper classes
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep the entry point
-keep class com.henry.memora.** { *; }

# SQLite / sqflite
-keep class org.sqlite.** { *; }

# Suppress warnings for common Flutter dependencies
-dontwarn io.flutter.embedding.**
