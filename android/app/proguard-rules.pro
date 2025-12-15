# Flutter Local Notifications için gerekli kurallar
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.google.gson.** { *; }

# Desugaring için gerekli olabilir
-keep class j$.** { *; }

# Eğer release modda hata devam ederse, R8'i biraz gevşetelim
-dontwarn com.dexterous.**