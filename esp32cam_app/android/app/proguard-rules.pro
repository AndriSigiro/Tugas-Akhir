# Keep TensorFlow Lite classes
-keep class org.tensorflow.lite.** { *; }
-keep interface org.tensorflow.lite.** { *; }

# Keep GPU delegate classes
-keep class org.tensorflow.lite.gpu.** { *; }

# Keep model classes
-keep class org.tensorflow.lite.support.** { *; }

# Don't warn about TensorFlow Lite
-dontwarn org.tensorflow.lite.**
-dontwarn org.tensorflow.lite.gpu.**

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}
