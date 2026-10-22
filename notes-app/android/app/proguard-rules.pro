# shared_preferences_android 2.5.0 calls its Kotlin side from Dart over
# JNI, looking classes and members up by name and signature. Neither it
# nor the jni package keeps what they look up, so R8 strips or renames
# them and release builds fail at SharedPreferences.getInstance().

# The plugin's own classes
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# Kotlin classes named in the plugin's signatures, and those the jni
# package uses to run suspend functions (lib/src/kotlin.dart)
-keep class kotlin.coroutines.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
-keep class kotlin.enums.EnumEntries { *; }
-keep class kotlin.jvm.internal.DefaultConstructorMarker { *; }
