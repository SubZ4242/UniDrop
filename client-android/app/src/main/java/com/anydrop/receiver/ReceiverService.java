package com.unidrop.receiver;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.IBinder;

public final class ReceiverService extends Service {
    public static final String PREFS = "unidrop";
    public static final String ACTION_START = "com.unidrop.receiver.START";
    public static final String ACTION_STOP = "com.unidrop.receiver.STOP";
    public static final String EXTRA_PORT = "port";
    public static final String KEY_PORT = "port";
    public static final String KEY_RUNNING = "running";
    public static final String KEY_AUTOSTART = "autostart";
    public static final String KEY_LAST_STATUS = "last_status";
    public static final String KEY_LAST_FILE_COUNT = "last_file_count";
    public static final String KEY_OUTPUT_TREE_URI = "output_tree_uri";
    public static final String KEY_GATEWAY_HOST = "gateway_host";
    public static final String KEY_GATEWAY_PORT = "gateway_port";
    private static final String CHANNEL_ID = "unidrop_receiver";
    private static final int NOTIFICATION_ID = 4242;

    private HttpReceiverServer server;
    private SharedPreferences prefs;

    @Override
    public void onCreate() {
        super.onCreate();
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        ensureChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopReceiver();
            stopSelf();
            return START_NOT_STICKY;
        }
        int port = intent == null ? prefs.getInt(KEY_PORT, 8873) : intent.getIntExtra(EXTRA_PORT, prefs.getInt(KEY_PORT, 8873));
        startForeground(NOTIFICATION_ID, notification("UniDrop bereit", "Empfängt auf Port " + port));
        startReceiver(port);
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopReceiver();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void startReceiver(int port) {
        stopReceiver();
        prefs.edit()
            .putInt(KEY_PORT, port)
            .putBoolean(KEY_RUNNING, false)
            .putString(KEY_LAST_STATUS, "startet")
            .apply();
        server = new HttpReceiverServer(this, port, (status, savedFiles) -> {
            prefs.edit()
                .putBoolean(KEY_RUNNING, status.running)
                .putString(KEY_LAST_STATUS, status.message)
                .putInt(KEY_LAST_FILE_COUNT, savedFiles)
                .apply();
            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.notify(NOTIFICATION_ID, notification("UniDrop bereit", status.message));
        });
        server.start();
    }

    private void stopReceiver() {
        if (server != null) {
            server.stop();
            server = null;
        }
        if (prefs != null) {
            prefs.edit().putBoolean(KEY_RUNNING, false).putString(KEY_LAST_STATUS, "gestoppt").apply();
        }
    }

    private Notification notification(String title, String text) {
        Intent activityIntent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this,
            1,
            activityIntent,
            Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0
        );
        Notification.Builder builder = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(this, CHANNEL_ID)
            : new Notification.Builder(this);
        return builder
            .setSmallIcon(com.unidrop.receiver.R.drawable.ic_drop)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build();
    }

    private void ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(
            CHANNEL_ID,
            "UniDrop Receiver",
            NotificationManager.IMPORTANCE_LOW
        );
        channel.setDescription("Lokaler UniDrop-Empfangsdienst");
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(channel);
    }

    public static final class ServerStatus {
        public final boolean running;
        public final String message;

        public ServerStatus(boolean running, String message) {
            this.running = running;
            this.message = message;
        }
    }

    public interface StatusListener {
        void onStatus(ServerStatus status, int savedFiles);
    }
}
