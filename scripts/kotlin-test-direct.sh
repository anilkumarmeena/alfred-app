#!/bin/sh
# The plugin's Kotlin unit tests (com.anil.jarvis.audio.core) without Gradle: Android Studio's bundled Kotlin
# compiler builds them, and JUnit runs them. For when Gradle can't download its plugins; normally use
# `npm run test:android`. OUT (default .build/kotlin) holds the build. Needs junit 4.13.2 and hamcrest 1.3 in
# ~/.gradle's cache (any earlier Android build puts them there).
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
plugin="$root/packages/jarvis-audio/android/src"
out="${1:-$root/.build/kotlin}"
studio="${ANDROID_STUDIO:-/Applications/Android Studio.app}"
kotlinc="$studio/Contents/plugins/Kotlin/kotlinc/lib"
java="$studio/Contents/jbr/Contents/Home/bin/java"
[ -x "$java" ] || java=java
cache="$HOME/.gradle/caches/modules-2/files-2.1"
junit="$(find "$cache/junit/junit/4.13.2" -name 'junit-4.13.2.jar' | head -1)"
hamcrest="$(find "$cache/org.hamcrest/hamcrest-core/1.3" -name 'hamcrest-core-1.3.jar' | head -1)"
[ -n "$junit" ] && [ -n "$hamcrest" ] || { echo "junit 4.13.2 / hamcrest-core 1.3 not in $cache" >&2; exit 1; }
mkdir -p "$out"

"$java" -cp "$kotlinc/kotlin-compiler.jar:$kotlinc/kotlin-stdlib.jar:$kotlinc/kotlin-script-runtime.jar:$kotlinc/kotlin-reflect.jar:$kotlinc/trove4j.jar:$kotlinc/kotlinx-coroutines-core-jvm.jar:$kotlinc/annotations-13.0.jar" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-reflect -jvm-target 17 -cp "$junit:$kotlinc/kotlin-stdlib.jar" \
  -d "$out" "$plugin"/main/java/com/anil/jarvis/audio/core/*.kt "$plugin"/test/java/com/anil/jarvis/audio/core/*.kt

tests=$(cd "$out" && find com -name '*Test.class' | sed 's/\.class$//; s#/#.#g' | tr '\n' ' ')
exec "$java" -cp "$out:$junit:$hamcrest:$kotlinc/kotlin-stdlib.jar" org.junit.runner.JUnitCore $tests
