package com.niki.xxread

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONTokener
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class SourceWebViewBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "com.niki.xxread/source_webview"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, CHANNEL)
    private val activeRequests = mutableMapOf<String, () -> Unit>()

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "cancel") {
                val requestId = call.argument<String>("requestId")
                val cancel = requestId?.let(activeRequests::get)
                if (cancel == null) {
                    result.success(false)
                } else {
                    cancel()
                    result.success(true)
                }
                return@setMethodCallHandler
            }
            if (call.method != "load" && call.method != "loadBytes") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val requestId = call.argument<String>("requestId")
            if (requestId.isNullOrBlank()) {
                result.error("invalid_request", "Background browser request ID is empty.", null)
                return@setMethodCallHandler
            }
            if (activeRequests.containsKey(requestId)) {
                result.error("duplicate_request", "Background browser request ID is already active.", null)
                return@setMethodCallHandler
            }
            val url = call.argument<String>("url")
            if (url.isNullOrBlank()) {
                result.error("invalid_url", "Background browser URL is empty.", null)
                return@setMethodCallHandler
            }
            val method = call.argument<String>("method")?.uppercase() ?: "GET"
            val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
                .entries
                .associate { "${it.key}" to "${it.value}" }
            val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 15_000L)
                .coerceIn(2_000L, 30_000L)
            if (call.method == "loadBytes") {
                val maxBytes = (call.argument<Number>("maxBytes")?.toInt() ?: 8 * 1024 * 1024)
                    .coerceIn(1, 24 * 1024 * 1024)
                loadBytes(requestId, url, headers, timeoutMs.toInt(), maxBytes, result)
                return@setMethodCallHandler
            }
            val body = call.argument<String>("body") ?: ""
            val webJs = call.argument<String>("webJs")
            val html = call.argument<String>("html")
            load(requestId, url, method, headers, body, webJs, html, timeoutMs, result)
        }
    }

    private fun loadBytes(
        requestId: String,
        url: String,
        headers: Map<String, String>,
        timeoutMs: Int,
        maxBytes: Int,
        result: MethodChannel.Result,
    ) {
        val completed = AtomicBoolean(false)
        val connection = AtomicReference<HttpURLConnection?>()

        fun cancel() {
            if (!completed.compareAndSet(false, true)) return
            connection.get()?.disconnect()
            activeRequests.remove(requestId)
            result.error("cancelled", "Platform byte request was cancelled.", null)
        }

        activeRequests[requestId] = ::cancel
        Thread {
            try {
                val openedConnection = (URL(url).openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = false
                    connectTimeout = timeoutMs
                    readTimeout = timeoutMs
                    requestMethod = "GET"
                    headers.forEach { (name, value) -> setRequestProperty(name, value) }
                }
                connection.set(openedConnection)
                if (completed.get()) return@Thread
                val status = openedConnection.responseCode
                val location = openedConnection.getHeaderField("Location")
                val stream = if (status in 200..299) openedConnection.inputStream else openedConnection.errorStream
                val output = ByteArrayOutputStream()
                if (stream != null) {
                    stream.use { input ->
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (output.size() + count > maxBytes) {
                                throw IllegalStateException("Response exceeds $maxBytes bytes.")
                            }
                            output.write(buffer, 0, count)
                        }
                    }
                }
                val payload = mapOf(
                    "statusCode" to status,
                    "bytes" to output.toByteArray(),
                    "location" to location,
                )
                handler.post {
                    if (!completed.compareAndSet(false, true)) return@post
                    activeRequests.remove(requestId)
                    result.success(payload)
                }
            } catch (error: Exception) {
                handler.post {
                    if (!completed.compareAndSet(false, true)) return@post
                    activeRequests.remove(requestId)
                    result.error("byte_load_failed", error.message ?: "Platform byte request failed.", null)
                }
            } finally {
                connection.getAndSet(null)?.disconnect()
            }
        }.start()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun load(
        requestId: String,
        url: String,
        method: String,
        headers: Map<String, String>,
        body: String,
        webJs: String?,
        html: String?,
        timeoutMs: Long,
        result: MethodChannel.Result,
    ) {
        val completed = AtomicBoolean(false)
        val webView = WebView(context)
        var navigationGeneration = 0
        var pendingCapture: Runnable? = null
        var pendingScriptCapture: Runnable? = null
        var timeoutCallback: Runnable? = null
        var destroyed = false
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            headers.entries.firstOrNull { it.key.equals("user-agent", true) }
                ?.value
                ?.takeIf { it.isNotBlank() }
                ?.let { userAgentString = it }
        }

        fun cleanup() {
            if (destroyed) return
            destroyed = true
            pendingCapture?.let(handler::removeCallbacks)
            pendingCapture = null
            pendingScriptCapture?.let(handler::removeCallbacks)
            pendingScriptCapture = null
            timeoutCallback?.let(handler::removeCallbacks)
            timeoutCallback = null
            activeRequests.remove(requestId)
            webView.stopLoading()
            webView.webViewClient = WebViewClient()
            webView.loadUrl("about:blank")
            webView.clearHistory()
            webView.removeAllViews()
            webView.destroy()
        }

        fun fail(code: String, message: String) {
            if (!completed.compareAndSet(false, true)) return
            result.error(code, message, null)
            cleanup()
        }

        fun capture() {
            if (completed.get()) return
            webView.evaluateJavascript(
                "(function(){return document.documentElement ? document.documentElement.outerHTML : document.body.innerHTML;})()",
            ) { encoded ->
                if (!completed.compareAndSet(false, true)) return@evaluateJavascript
                val html = try {
                    JSONTokener(encoded).nextValue() as? String ?: ""
                } catch (_: Exception) {
                    ""
                }
                if (html.isEmpty()) {
                    result.error("empty_page", "Background browser returned an empty page.", null)
                } else {
                    result.success(
                        mapOf(
                            "body" to html,
                            "finalUrl" to (webView.url ?: url),
                            "cookieHeader" to CookieManager.getInstance()
                                .getCookie(webView.url ?: url),
                        ),
                    )
                }
                cleanup()
            }
        }

        activeRequests[requestId] = {
            fail("cancelled", "Background browser request was cancelled.")
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, startedUrl: String, favicon: android.graphics.Bitmap?) {
                navigationGeneration++
                pendingCapture?.let(handler::removeCallbacks)
                pendingCapture = null
                pendingScriptCapture?.let(handler::removeCallbacks)
                pendingScriptCapture = null
            }

            override fun onPageFinished(view: WebView, finishedUrl: String) {
                if (completed.get() || finishedUrl == "about:blank") return
                val finishedGeneration = navigationGeneration
                pendingCapture?.let(handler::removeCallbacks)
                pendingCapture = Runnable {
                    pendingCapture = null
                    if (completed.get()) return@Runnable
                    if (finishedGeneration != navigationGeneration || view.progress < 100) {
                        return@Runnable
                    }
                    if (webJs.isNullOrBlank()) {
                        capture()
                    } else {
                        view.evaluateJavascript(webJs) {
                            if (completed.get()) return@evaluateJavascript
                            pendingScriptCapture = Runnable {
                                pendingScriptCapture = null
                                capture()
                            }
                            handler.postDelayed(pendingScriptCapture!!, 250L)
                        }
                    }
                }
                handler.postDelayed(pendingCapture!!, 750L)
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    fail("load_failed", "Background browser load failed: ${error.description}")
                }
            }
        }

        timeoutCallback = Runnable {
            fail("timeout", "Background browser timed out while loading this source.")
        }
        handler.postDelayed(timeoutCallback!!, timeoutMs)

        val cookie = headers.entries.firstOrNull { it.key.equals("cookie", true) }?.value
        if (!cookie.isNullOrBlank()) {
            CookieManager.getInstance().setCookie(url, cookie)
            CookieManager.getInstance().flush()
        }
        val navigationHeaders = headers.filterKeys {
            !it.equals("cookie", true) && !it.equals("user-agent", true)
        }
        if (!html.isNullOrEmpty()) {
            webView.loadDataWithBaseURL(url, html, "text/html", "UTF-8", null)
        } else if (method == "POST") {
            webView.postUrl(url, body.toByteArray(Charsets.UTF_8))
        } else {
            webView.loadUrl(url, navigationHeaders)
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        activeRequests.values.toList().forEach { it() }
        activeRequests.clear()
    }
}
