package com.unidrop.receiver;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;

public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }
        SharedPreferences prefs = context.getSharedPreferences(ReceiverService.PREFS, Context.MODE_PRIVATE);
        if (!prefs.getBoolean(ReceiverService.KEY_AUTOSTART, false)) {
            return;
        }
        Intent service = new Intent(context, ReceiverService.class)
            .setAction(ReceiverService.ACTION_START)
            .putExtra(ReceiverService.EXTRA_PORT, prefs.getInt(ReceiverService.KEY_PORT, 8873));
        if (Build.VERSION.SDK_INT >= 26) {
            context.startForegroundService(service);
        } else {
            context.startService(service);
        }
    }
}
