# ProGuard rules for Secure Insta Message
#
# Keep TorService and MainActivity (accessed via reflection by Flutter)

-keep class com.securemessage.app.TorService { *; }
-keep class com.securemessage.app.MainActivity { *; }

# Keep Kotlin metadata
-keepattributes *Annotation*

# Keep Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }

# Keep MethodChannel handler classes
-keepclassmembers class * {
    @io.flutter.plugin.common.MethodChannel$MethodCallHandler <methods>;
}

# Preserve enum values
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
