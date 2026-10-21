package com.hme.bluetoothle.background;

import java.util.ArrayList;
import java.util.List;

/** Main-loop ownership gate; retirement and release are asynchronous and fail closed. */
public final class BLEBackgroundOwnership {
    public interface Host {
        void retireParent(BLEBackgroundProtocol.Done done);
        void connectNative();
        void stopNative(BLEBackgroundProtocol.Done done);
        void failure(String error);
    }
    private final Host host;
    public boolean armed, ownsBluetooth;
    private boolean background, retiring, suspending, parentRetired;
    private int generation;
    private final List<BLEBackgroundProtocol.Done> retirementWaiters = new ArrayList<>();
    private final List<BLEBackgroundProtocol.Done> suspensionWaiters = new ArrayList<>();
    public BLEBackgroundOwnership(Host host) { this.host = host; }
    public void arm() { armed = true; }
    private void retire(BLEBackgroundProtocol.Done done) {
        retirementWaiters.add(done);
        if (retiring) return;
        retiring = true;
        host.retireParent(error -> {
            retiring = false;
            if (error == null) parentRetired = true;
            List<BLEBackgroundProtocol.Done> callbacks = new ArrayList<>(retirementWaiters); retirementWaiters.clear();
            for (BLEBackgroundProtocol.Done callback : callbacks) callback.complete(error);
        });
    }
    public void pause() {
        background = true;
        if (!armed || ownsBluetooth) return;
        ownsBluetooth = true;
        parentRetired = false;
        int revision = ++generation;
        retire(error -> {
            if (error != null) { host.failure(error); return; }
            if (revision == generation && background && armed) host.connectNative();
        });
    }
    public void suspend(boolean disarm, BLEBackgroundProtocol.Done done) {
        background = false; generation++;
        if (disarm) armed = false;
        if (!ownsBluetooth) { done.complete(null); return; }
        suspensionWaiters.add(done);
        if (suspending) return;
        suspending = true;
        // Wait for an in-flight parent retirement as well as native disconnection.
        BLEBackgroundProtocol.Done retired = error -> {
            // Even a failed parent retirement must not leave the native monitor running after disarm.
            host.stopNative(nativeError -> {
                String failure = error == null ? nativeError : error;
                if (failure == null) ownsBluetooth = false; else host.failure(failure);
                suspending = false;
                List<BLEBackgroundProtocol.Done> callbacks = new ArrayList<>(suspensionWaiters); suspensionWaiters.clear();
                for (BLEBackgroundProtocol.Done callback : callbacks) callback.complete(failure);
                if (failure == null && background && armed && !ownsBluetooth) pause();
            });
        };
        if (parentRetired) retired.complete(null); else retire(retired);
    }
}
