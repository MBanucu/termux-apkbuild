package com.example.apkbuildlib;

/** References a resource so a broken R.txt or static-lib link cannot pass. */
public final class Greeting {
    private Greeting() {
    }

    public static int nameResource() {
        return R.string.lib_name;
    }

    public static String hello() {
        return "hello from apkbuild";
    }
}
