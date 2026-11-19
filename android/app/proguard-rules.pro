# Hotwire Native ships its own keep rules (consumer ProGuard files in its AARs).

# Hotwire finds fragment destinations by their @HotwireDestinationDeepLink annotation, with Kotlin
# reflection, so the app's destination classes and the annotation must survive shrinking.
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault,*Annotation*
-keep @dev.hotwire.navigation.destinations.HotwireDestinationDeepLink class * { *; }
-keep class kotlin.Metadata { *; }

# OkHttp's optional platform integrations.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
