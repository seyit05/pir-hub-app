@echo off
REM Yerel APK derlemesi (JAVA_HOME, Android SDK ve Flutter yollarini ayarlar)
set "JAVA_HOME=%USERPROFILE%\jdk-17.0.13+11"
set "ANDROID_SDK_ROOT=%USERPROFILE%\Android\sdk"
set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
set "PATH=%USERPROFILE%\flutter\bin;%PATH%"
cd /d "%~dp0"
flutter build apk --release
echo.
echo Cikti: build\app\outputs\flutter-apk\app-release.apk
