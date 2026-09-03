package nodejsmobile.test.testnode;

import android.content.Context;
import android.content.Intent;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.UUID;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

/**
 * Real-device smoke, self-driving so it can run on BrowserStack App
 * Automate (Espresso) where there is no adb/proxy harness. The CI workflow
 * stages bs-smoke.js, test-napi-addon.js and the prebuilt crcnative.node into
 * this test APK's assets (src/androidTest/assets/, created at build time).
 *
 * The test copies them into the app sandbox, launches MainActivity with the
 * same intent contract the proxy harness uses (nodeargs + runtoken), and
 * asserts the per-launch verdict file the native layer writes
 * (<filesDir>/result-<token>.txt) reads PASS — i.e. node booted, ran the
 * smoke script, loaded the N-API addon, and drained the loop with exit 0.
 */
@RunWith(AndroidJUnit4.class)
public class NodeSmokeTest {

    // Node boot + addon on a device is seconds; generous budget for slow
    // devices and first-launch dex/verifier work.
    private static final int VERDICT_TIMEOUT_MS = 240_000;
    private static final int POLL_INTERVAL_MS = 1_000;

    @Test
    public void nodeBootsAndLoadsNapiAddon() throws Exception {
        Context appCtx = InstrumentationRegistry.getInstrumentation().getTargetContext();
        Context testCtx = InstrumentationRegistry.getInstrumentation().getContext();

        File filesDir = appCtx.getFilesDir();
        File testDir = new File(filesDir, "test");
        testDir.mkdirs();

        // Stage the smoke script + addon test next to each other (bs-smoke.js
        // does require('./test-napi-addon.js')), and the addon binary at the
        // path native-lib.cpp exports as NODE_MOBILE_ADDON
        // (<filesDir>/crcnative.node).
        copyAsset(testCtx, "bs-smoke.js", new File(testDir, "bs-smoke.js"));
        copyAsset(testCtx, "test-napi-addon.js", new File(testDir, "test-napi-addon.js"));
        copyAsset(testCtx, "crcnative.node", new File(filesDir, "crcnative.node"));

        String token = UUID.randomUUID().toString().substring(0, 8);
        File verdictFile = new File(filesDir, "result-" + token + ".txt");
        if (verdictFile.exists()) {
            assertTrue("stale verdict file could not be removed", verdictFile.delete());
        }

        Intent intent = new Intent(appCtx, MainActivity.class);
        intent.putExtra("nodeargs", new File(testDir, "bs-smoke.js").getAbsolutePath());
        intent.putExtra("runtoken", token);

        try (ActivityScenario<MainActivity> ignored = ActivityScenario.launch(intent)) {
            long deadline = System.currentTimeMillis() + VERDICT_TIMEOUT_MS;
            while (System.currentTimeMillis() < deadline) {
                if (verdictFile.exists()) {
                    String verdict = readAll(verdictFile).trim();
                    assertEquals("node smoke verdict", "PASS", verdict);
                    return;
                }
                Thread.sleep(POLL_INTERVAL_MS);
            }
        }
        fail("no verdict file after " + (VERDICT_TIMEOUT_MS / 1000)
                + "s — node did not finish (see logcat tag TestNode in device logs)");
    }

    private static void copyAsset(Context testCtx, String name, File dest) throws IOException {
        try (InputStream in = testCtx.getAssets().open(name);
             OutputStream out = new FileOutputStream(dest)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        }
    }

    private static String readAll(File f) throws IOException {
        try (InputStream in = new FileInputStream(f)) {
            StringBuilder sb = new StringBuilder();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) != -1) sb.append(new String(buf, 0, n, "UTF-8"));
            return sb.toString();
        }
    }
}
