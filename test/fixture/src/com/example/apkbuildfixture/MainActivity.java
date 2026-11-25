package com.example.apkbuildfixture;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

/** The smallest app that proves link, javac, d8, package and sign ran. */
public final class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setText(getString(R.string.app_name));
        setContentView(text);
    }
}
