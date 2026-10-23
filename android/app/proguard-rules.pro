# --- LiteRT / TensorFlow Lite support -------------------------------------
# Without these keeps R8 breaks the ColorSpaceType switch inside
# litert-support and the release build fails at runtime with:
#   UnsupportedOperationException: getNormalizedShape() is unsupported for the
#   color space type RGB
-keep class org.tensorflow.lite.** { *; }
-keep class com.google.ai.edge.litert.** { *; }
-keepclassmembers class org.tensorflow.lite.** { *; }
-keepclassmembers class com.google.ai.edge.litert.** { *; }
-dontwarn org.tensorflow.lite.**

# --- OpenCV ---------------------------------------------------------------
# org.opencv Java classes are bound to native symbols by name; renaming them
# breaks JNI lookups (`Java_org_opencv_core_Mat_n_1delete`, ...).
-keep class org.opencv.** { *; }
-keepclassmembers class org.opencv.** { *; }
