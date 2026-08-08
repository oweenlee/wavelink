allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}
subprojects.apply {
    plugins.withId("org.jetbrains.kotlin.android") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}
// AGP 8+/9 强制要求 `namespace`，但部分老旧 Flutter 插件（如 on_audio_query_android）
// 仍只在 AndroidManifest.xml 声明 package。在 android library 插件应用时自动注入 namespace。
subprojects {
    plugins.withId("com.android.library") {
        val androidExt = extensions.findByName("android") ?: return@withId
        val getter = androidExt.javaClass.methods
            .firstOrNull { it.name == "getNamespace" } ?: return@withId
        val current = getter.invoke(androidExt) as? String
        if (!current.isNullOrEmpty()) return@withId
        val manifest = file("src/main/AndroidManifest.xml")
        if (!manifest.exists()) return@withId
        val pkg = Regex("""package\s*=\s*"([^"]+)"""")
            .find(manifest.readText())?.groupValues?.get(1) ?: return@withId
        val setter = androidExt.javaClass.methods
            .firstOrNull { it.name == "setNamespace" } ?: return@withId
        setter.invoke(androidExt, pkg)
        logger.lifecycle("[namespace-patch] :${project.name} -> $pkg")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
