package zhou.solab.tools

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.android.apksig.ApkSigner
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.json.JSONObject
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Date
import java.util.zip.ZipFile

/**
 * APK v1/v2/v3 签名。
 *
 * 内置签名密钥：首次生成存 Android Keystore（系统硬件背书托管，无私钥文件、
 * 无硬编码口令），之后复用。与官方签名不同，覆盖安装原 App 需先卸载。
 * 密钥采用 EC P-256（ECDSA，SHA256withECDSA）。
 */
object SolabApkBuildTool {

    private const val KEY_ALIAS = "niehe"

    /** 内置签名密钥：Android Keystore 托管（首次生成自签名证书，之后复用）。 */
    fun obtainSigner(context: Context): Pair<PrivateKey, X509Certificate> {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = runCatching {
            val key = ks.getKey(KEY_ALIAS, null) as PrivateKey
            val cert = ks.getCertificate(KEY_ALIAS) as X509Certificate
            key to cert
        }.getOrNull()
        if (existing != null) return existing

        // 生成 EC P-256 密钥对（Android Keystore，不可导出）
        val kpGen = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore",
        )
        kpGen.initialize(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN,
            )
                .setAlgorithmParameterSpec(java.security.spec.ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build(),
        )
        val kp = kpGen.generateKeyPair()
        // 自签名 X509v3 证书（30 年有效）
        val now = System.currentTimeMillis()
        val notBefore = Date(now - 24L * 3600 * 1000)
        val notAfter = Date(now + 30L * 365 * 24 * 3600 * 1000)
        val dn = X500Name("CN=NieHe, O=XuanXing, C=CN")
        val builder = JcaX509v3CertificateBuilder(
            dn, BigInteger.valueOf(now), notBefore, notAfter, dn, kp.public,
        )
        val signer = JcaContentSignerBuilder("SHA256withECDSA").build(kp.private)
        val cert = JcaX509CertificateConverter().getCertificate(builder.build(signer))
        // 证书链存入 Keystore 供后续复用
        ks.setKeyEntry(KEY_ALIAS, kp.private, null, arrayOf(cert))
        return kp.private to cert
    }

    /** A4: APK v1/v2/v3 签名。 */
    fun apkSign(context: Context, args: JSONObject): JSONObject {
        val inputPath = args.str("inputApk").ifBlank { args.str("path") }
        if (inputPath.isBlank()) return err("INVALID_ARGUMENT", "缺少 inputApk", "inputApk", "")
        val input = File(inputPath)
        if (!input.isFile) return err("FILE_NOT_FOUND", "APK 不存在: $inputPath", "inputApk", inputPath)
        val output = args.str("outputApk").ifBlank {
            File(input.parentFile, "SoLab/output").apply { mkdirs() }
                .resolve("${input.nameWithoutExtension}-signed.apk")
                .absolutePath
        }
        return runCatching {
            val (key, cert) = obtainSigner(context)
            val multiplexed = ZipFile(input).use {
                it.getEntry("assets/solab/original.apk") != null
            }
            if (multiplexed) {
                signMultiplexedApk(
                    input,
                    File(output),
                    key,
                    cert,
                    args.intValue("minSdk", 26),
                )
            } else {
                signApkWithKey(input, File(output), key, cert, args.intValue("minSdk", 26))
            }
            ok(JSONObject()
                .put("tool", "apk_sign")
                .put("success", true)
                .put("outputApk", output)
                .put("signer", "CN=NieHe (内置自签名密钥 EC P-256)")
                .put("dataMultiplexing", multiplexed)
                .put("hint", "已签名,可直接安装。用内置密钥,与官方签名不同,覆盖安装原 App 需先卸载。"))
        }.getOrElse { e ->
            // 失败时 apksig 可能已写出部分字节（Malformed APK 残留），必须清除，
            // 否则工作目录会积累损坏的 *-signed.apk 干扰后续 list/验签。
            runCatching { File(output).delete() }
            // 完整根因链：NIEHE 故障排查需要 cause 栈（Keystore/apksig 均可能抛多层）
            val causeChain = generateSequence<Throwable>(e) { it.cause }.take(4)
                .joinToString(" <- ") { "${it.javaClass.simpleName}: ${it.message}" }
            err("APK_SIGN_FAILED", "APK 签名失败: $causeChain", "inputApk", inputPath)
        }
    }

    /** 纯签名逻辑（JVM 可测）：v1/v2/v3 签名 input → output。 */
    fun signApkWithKey(
        input: File,
        output: File,
        key: PrivateKey,
        cert: X509Certificate,
        minSdk: Int = 26,
        v1Enabled: Boolean = true,
        v2Enabled: Boolean = true,
        v3Enabled: Boolean = true,
    ) {
        val signerConfig = ApkSigner.SignerConfig.Builder("NIEHE", key, listOf(cert)).build()
        ApkSigner.Builder(listOf(signerConfig))
            .setInputApk(input)
            .setOutputApk(File(output.absolutePath))
            .setMinSdkVersion(minSdk)
            .setV1SigningEnabled(v1Enabled)
            .setV2SigningEnabled(v2Enabled)
            .setV3SigningEnabled(v3Enabled)
            .build()
            .sign()
    }

    private fun signMultiplexedApk(
        input: File,
        output: File,
        key: PrivateKey,
        cert: X509Certificate,
        minSdk: Int,
    ) {
        val expanded = File(output.parentFile, output.name + ".signing.tmp")
        expanded.delete()
        try {
            signApkWithKey(
                input,
                expanded,
                key,
                cert,
                minSdk,
                v1Enabled = true,
                v2Enabled = false,
                v3Enabled = false,
            )
            bin.zip.DataMultiplexing.optimize(
                expanded,
                output,
                "assets/solab/original.apk",
                false,
            )
            bin.mt.apksign.V2V3SchemeSigner.sign(
                output,
                object : bin.mt.apksign.key.SignatureKey {
                    override fun getCertificate(): X509Certificate = cert

                    override fun getPrivateKey(): PrivateKey = key
                },
                true,
                true,
            )
        } finally {
            expanded.delete()
        }
    }
}
