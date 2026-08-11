package nodejsmobile.test.testnode;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.content.res.AssetManager;
import java.io.*;
import java.lang.System;

public class MainActivity extends Activity {

    private static AssetManager assetManager = null;
    private static String TAG = "TestNode";

    // Used to load the 'native-lib' library on application startup.
    static {
        System.loadLibrary("native-lib");
        System.loadLibrary("node");
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        // Get the args for node
        String nodeArgs = getIntent().getStringExtra("nodeargs");

        if (nodeArgs == null) {
            // Note: use Log.v to keep the app logging diversified from
            // the node logging that uses Log.i and Log.e
            Log.v(TAG, "No input args, copying assets...");
            this.assetManager = this.getAssets();
            try {
                copyTestAssets();
            } catch (IOException e) {
                e.printStackTrace();
                Log.v(TAG, "COPYASSETS:FAIL");
                return;
            }
            Log.v(TAG, "COPYASSETS:PASS");
            return;
        }
        String nodeSubstituteDir=getIntent().getStringExtra("substitutedir");
        // Per-launch token (see native-lib.cpp): passed out-of-band as its own
        // extra so it never leaks into the test's process.argv. Names the verdict
        // file the native code / proxy use.
        final String runToken = getIntent().getStringExtra("runtoken");

        if (nodeArgs.startsWith("-p")) {
            RunNode("node " + nodeArgs, runToken);
        } else {
            final String testFolderPath = this.getBaseContext().getFilesDir().getAbsolutePath() + "/test/";
            String[] parts = nodeArgs.split(" ");
            String newArgs = "";
            // Substring replacement (not a startsWith prefix check) so a path
            // embedded inside a flag is also rewritten to the on-device test dir,
            // e.g. --test-reporter=./test/common/test-error-reporter.js. Mirrors
            // the iOS main.m rewriter; the prefix check missed flag-embedded paths
            // and broke node:test-style tests with ERR_MODULE_NOT_FOUND.
            for (int i = 0; i < ( parts.length ); i++) {
                String a = parts[i];
                if (nodeSubstituteDir != null) {
                    a = a.replace(nodeSubstituteDir, testFolderPath);
                }
                a = a.replace("./test/", testFolderPath);
                newArgs += a + " ";
            }
            // Run node directly on the test file; the verdict comes from the
            // native exit-code -> sandbox result file, no -r marker shim needed.
            newArgs = "node " + newArgs;
            RunNode(newArgs, runToken);
        }
    }

    /**
     * A native method that is implemented by the 'native-lib' native library,
     * which is packaged with this application.
     */
    public native Integer startNodeWithArguments(String[] arguments, String nodePath, boolean redirectOutputToLogcat, String runToken);

    private void RunNode(String args, final String runToken) {
        Log.v(TAG, "Args: " + args);

        final String testFolderPath = this.getBaseContext().getFilesDir().getAbsolutePath();
        final String[] parts = args.split(" ");

        Thread mainNodeThread = new Thread(new Runnable() {
            @Override
            public void run() {
                startNodeWithArguments(
                        parts,
                        testFolderPath,
                        true,
                        runToken);
            }
        });
        mainNodeThread.setUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            //If the node thread throws a Java exception, record FAIL in the
            //verdict file the proxy reads (mirrors the native atexit fallback).
            //Write only if no verdict exists yet: the native post-run write
            //(PASS/FAIL) runs inside the JNI call and completes before any
            //exception could surface on this thread, so honour it rather than
            //clobber it.
            public void uncaughtException(Thread t, Throwable e) {
                File rf = new File(testFolderPath + "/result-" + runToken + ".txt");
                if (rf.exists()) return;
                try (FileWriter w = new FileWriter(rf)) {
                    w.write("FAIL\n");
                } catch (IOException ignored) {}
            }
        });
        mainNodeThread.start();
    }

    private void copyTestAssets() throws IOException {
        String destFolder = this.getBaseContext().getFilesDir().getAbsolutePath() + "/test";
        File folderObject = new File(destFolder);
        if (folderObject.exists()) {
            deleteFolderRecursively(folderObject);
        }
        enumerateAssetFolder("", destFolder);
    }

    private void enumerateAssetFolder(String srcFolder, String destPath) throws IOException {
        String[] files = assetManager.list(srcFolder);

        if (files.length == 0) {
            copyAssetFile(srcFolder, destPath);
        } else {
            new File(destPath).mkdirs();
            for (String file : files) {
                if (srcFolder.equals("")) {
                    enumerateAssetFolder(file, destPath + "/" + file);
                } else {
                    enumerateAssetFolder(srcFolder + "/" + file, destPath + "/" + file);
                }
            }
        }
    }

    private void copyAssetFile(String srcFolder, String destPath) throws IOException {
        InputStream in = assetManager.open(srcFolder);
        new File(destPath).createNewFile();
        OutputStream out = new FileOutputStream(destPath);
        copyFile(in, out);
        in.close();
        in = null;
        out.flush();
        out.close();
        out = null;
    }

    private void copyFile(InputStream in, OutputStream out) throws IOException {
        byte[] buffer = new byte[1024];
        int read;
        while ((read = in.read(buffer)) != -1) {
            out.write(buffer, 0, read);
        }
    }

    private void deleteFolderRecursively(File file) throws IOException {
        for (File childFile : file.listFiles()) {
            if (childFile.isDirectory()) {
                deleteFolderRecursively(childFile);
            } else {
                childFile.delete();
            }
        }
        file.delete();
    }
}
