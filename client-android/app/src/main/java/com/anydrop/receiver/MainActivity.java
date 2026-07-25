package com.unidrop.receiver;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.DocumentsContract;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.net.Inet4Address;
import java.net.HttpURLConnection;
import java.net.NetworkInterface;
import java.net.URL;
import java.util.Collections;
import java.util.concurrent.CompletionService;
import java.util.concurrent.ExecutorCompletionService;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private TextView statusView;
    private TextView urlView;
    private TextView folderView;
    private TextView gatewayView;
    private EditText portField;
    private CheckBox autostartCheck;
    private SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences(ReceiverService.PREFS, MODE_PRIVATE);
        requestNotificationPermissionIfNeeded();
        buildUi();
        refreshUi();
        if (prefs.getString(ReceiverService.KEY_GATEWAY_HOST, "").isEmpty()) {
            gatewayView.postDelayed(this::discoverMacGateway, 700);
        }
        statusView.postDelayed(this::startReceiver, 300);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshUi();
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(22), dp(22), dp(22), dp(22));
        root.setBackgroundColor(Color.rgb(246, 247, 249));
        setContentView(root);

        TextView icon = new TextView(this);
        icon.setText("💧");
        icon.setTextSize(40);
        root.addView(icon);

        TextView title = new TextView(this);
        title.setText("UniDrop Receiver");
        title.setTextSize(24);
        title.setTextColor(Color.rgb(30, 30, 34));
        title.setGravity(Gravity.START);
        title.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        root.addView(title);

        statusView = new TextView(this);
        statusView.setTextSize(16);
        statusView.setTextColor(Color.rgb(95, 95, 105));
        root.addView(statusView);

        urlView = new TextView(this);
        urlView.setTextSize(15);
        urlView.setTextColor(Color.rgb(30, 30, 34));
        urlView.setPadding(0, dp(18), 0, dp(12));
        root.addView(urlView);

        gatewayView = new TextView(this);
        gatewayView.setTextSize(15);
        gatewayView.setTextColor(Color.rgb(30, 30, 34));
        gatewayView.setPadding(0, dp(6), 0, dp(10));
        root.addView(gatewayView);

        Button discoverGateway = new Button(this);
        discoverGateway.setText("Mac suchen");
        discoverGateway.setOnClickListener(v -> discoverMacGateway());
        root.addView(discoverGateway, new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(52)
        ));

        TextView portLabel = new TextView(this);
        portLabel.setText("Port");
        portLabel.setTextColor(Color.rgb(70, 70, 78));
        root.addView(portLabel);

        portField = new EditText(this);
        portField.setSingleLine(true);
        portField.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
        portField.setText(String.valueOf(prefs.getInt(ReceiverService.KEY_PORT, 8873)));
        root.addView(portField);

        autostartCheck = new CheckBox(this);
        autostartCheck.setText("Mit Android starten");
        autostartCheck.setChecked(prefs.getBoolean(ReceiverService.KEY_AUTOSTART, false));
        autostartCheck.setOnCheckedChangeListener((CompoundButton buttonView, boolean isChecked) ->
            prefs.edit().putBoolean(ReceiverService.KEY_AUTOSTART, isChecked).apply()
        );
        root.addView(autostartCheck);

        folderView = new TextView(this);
        folderView.setTextColor(Color.rgb(70, 70, 78));
        folderView.setPadding(0, dp(12), 0, 0);
        root.addView(folderView);

        Button folderButton = new Button(this);
        folderButton.setText("Zielordner auswählen");
        folderButton.setOnClickListener(v -> chooseOutputFolder());
        root.addView(folderButton, new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(52)
        ));

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER);
        buttons.setPadding(0, dp(18), 0, 0);
        root.addView(buttons);

        Button saveStart = new Button(this);
        saveStart.setText("Empfänger starten");
        saveStart.setOnClickListener(v -> startReceiver());
        buttons.addView(saveStart, new LinearLayout.LayoutParams(0, dp(52), 1));

        Button stop = new Button(this);
        stop.setText("Stoppen");
        stop.setOnClickListener(v -> stopReceiver());
        LinearLayout.LayoutParams stopParams = new LinearLayout.LayoutParams(0, dp(52), 1);
        stopParams.setMargins(dp(10), 0, 0, 0);
        buttons.addView(stop, stopParams);

        Button battery = new Button(this);
        battery.setText("Akku-Optimierung öffnen");
        battery.setOnClickListener(v -> openBatterySettings());
        LinearLayout.LayoutParams batteryParams = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(52)
        );
        batteryParams.setMargins(0, dp(16), 0, 0);
        root.addView(battery, batteryParams);

        TextView note = new TextView(this);
        note.setText("Standard: Downloads/UniDrop. Für dauerhaft zuverlässigen Empfang auf Samsung die Akku-Optimierung für UniDrop ausschalten.");
        note.setTextColor(Color.rgb(95, 95, 105));
        note.setPadding(0, dp(18), 0, 0);
        root.addView(note);
    }

    private void startReceiver() {
        int port = parsePort();
        prefs.edit().putInt(ReceiverService.KEY_PORT, port).apply();
        Intent intent = new Intent(this, ReceiverService.class)
            .setAction(ReceiverService.ACTION_START)
            .putExtra(ReceiverService.EXTRA_PORT, port);
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
        statusView.setText("Status: startet...");
        statusView.postDelayed(this::refreshUi, 800);
    }

    private void stopReceiver() {
        Intent intent = new Intent(this, ReceiverService.class).setAction(ReceiverService.ACTION_STOP);
        startService(intent);
        statusView.postDelayed(this::refreshUi, 500);
    }

    private int parsePort() {
        try {
            int port = Integer.parseInt(portField.getText().toString().trim());
            if (port >= 1024 && port <= 65535) {
                return port;
            }
        } catch (NumberFormatException ignored) {
        }
        portField.setText("8873");
        return 8873;
    }

    private void refreshUi() {
        boolean running = prefs.getBoolean(ReceiverService.KEY_RUNNING, false);
        int port = prefs.getInt(ReceiverService.KEY_PORT, 8873);
        String last = prefs.getString(ReceiverService.KEY_LAST_STATUS, "");
        String ip = localIpv4();
        String gatewayHost = prefs.getString(ReceiverService.KEY_GATEWAY_HOST, "");
        statusView.setText(running ? "Status: running" : "Status: stopped" + (last.isEmpty() ? "" : " · " + last));
        urlView.setText(ip == null
            ? "Telefon-WLAN-IP nicht gefunden. WLAN prüfen."
            : "Empfänger-URL: http://" + ip + ":" + port);
        gatewayView.setText(gatewayHost == null || gatewayHost.isEmpty()
            ? "Mac-Gateway: nicht gesucht"
            : "Mac-Gateway: http://" + gatewayHost + ":" + port + "/gateway");
        String tree = prefs.getString(ReceiverService.KEY_OUTPUT_TREE_URI, "");
        folderView.setText(tree == null || tree.isEmpty()
            ? "Zielordner: Downloads/UniDrop"
            : "Zielordner: ausgewählter Android-Ordner");
    }

    private void discoverMacGateway() {
        int port = parsePort();
        prefs.edit().putInt(ReceiverService.KEY_PORT, port).apply();
        gatewayView.setText("Mac-Gateway: suche...");
        new Thread(() -> {
            String host = findGatewayHost(port);
            runOnUiThread(() -> {
                if (host == null) {
                    prefs.edit().remove(ReceiverService.KEY_GATEWAY_HOST).apply();
                    gatewayView.setText("Mac-Gateway: nicht gefunden");
                } else {
                    prefs.edit()
                        .putString(ReceiverService.KEY_GATEWAY_HOST, host)
                        .putInt(ReceiverService.KEY_PORT, port)
                        .apply();
                    refreshUi();
                }
            });
        }, "unidrop-gateway-scan").start();
    }

    private void chooseOutputFolder() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
            | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        startActivityForResult(intent, 42);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != 42 || resultCode != RESULT_OK || data == null || data.getData() == null) {
            return;
        }
        Uri uri = data.getData();
        int flags = data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        try {
            getContentResolver().takePersistableUriPermission(uri, flags);
        } catch (SecurityException ignored) {
        }
        prefs.edit().putString(ReceiverService.KEY_OUTPUT_TREE_URI, uri.toString()).apply();
        refreshUi();
    }

    private String localIpv4() {
        try {
            for (NetworkInterface networkInterface : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!networkInterface.isUp() || networkInterface.isLoopback()) {
                    continue;
                }
                for (java.net.InetAddress address : Collections.list(networkInterface.getInetAddresses())) {
                    if (address instanceof Inet4Address && !address.isLoopbackAddress()) {
                        String ip = address.getHostAddress();
                        if (ip.startsWith("192.168.") || ip.startsWith("10.") || ip.startsWith("172.")) {
                            return ip;
                        }
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    private String findGatewayHost(int port) {
        String ownIp = localIpv4();
        if (ownIp == null) {
            return null;
        }
        int lastDot = ownIp.lastIndexOf('.');
        if (lastDot <= 0) {
            return null;
        }
        String prefix = ownIp.substring(0, lastDot + 1);
        ExecutorService executor = Executors.newFixedThreadPool(32);
        CompletionService<String> completion = new ExecutorCompletionService<>(executor);
        int submitted = 0;
        for (int i = 1; i <= 254; i++) {
            String host = prefix + i;
            if (host.equals(ownIp)) {
                continue;
            }
            completion.submit(() -> isUniDropGateway(host, port) ? host : "");
            submitted++;
        }
        try {
            for (int i = 0; i < submitted; i++) {
                String host = completion.take().get();
                if (!host.isEmpty()) {
                    executor.shutdownNow();
                    return host;
                }
            }
            return null;
        } catch (Exception ignored) {
            return null;
        } finally {
            executor.shutdownNow();
        }
    }

    private boolean isUniDropGateway(String host, int port) {
        HttpURLConnection connection = null;
        try {
            URL url = new URL("http://" + host + ":" + port + "/gateway");
            connection = (HttpURLConnection) url.openConnection();
            connection.setConnectTimeout(300);
            connection.setReadTimeout(300);
            connection.setRequestMethod("GET");
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                return false;
            }
            byte[] buffer = new byte[2048];
            int read = connection.getInputStream().read(buffer);
            if (read <= 0) {
                return false;
            }
            String body = new String(buffer, 0, read, java.nio.charset.StandardCharsets.UTF_8);
            return body.contains("\"app\":\"UniDrop\"") && body.contains("\"role\":\"mac-gateway\"");
        } catch (Exception ignored) {
            return false;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private void openBatterySettings() {
        try {
            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
        } catch (Exception ignored) {
            startActivity(new Intent(Settings.ACTION_SETTINGS));
        }
    }

    private void requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 10);
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
