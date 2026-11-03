# libpag looks its Java classes up by name from native code (JNI FindClass in JNI_OnLoad); R8 must not rename or remove them.
-keep class org.libpag.** { *; }
-keep class com.tencent.** { *; }
-dontwarn org.libpag.**
