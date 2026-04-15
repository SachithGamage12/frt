const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");

admin.initializeApp();

// Set global options to match your database region
setGlobalOptions({ region: "asia-south1" });

/**
 * Cloud Function Phase 16: Crash-Proof VoIP.
 * Optimized for Manual Native PushKit/CallKit Bridge.
 */
exports.oncallcreated = onDocumentCreated("calls/{userId}", async (event) => {
    const snapshot = event.data;
    if (!snapshot) return null;

    const callData = snapshot.data();
    const targetUserId = event.params.userId;

    if (callData.status !== "ringing") return null;

    // Fetch target user platform
    const userDoc = await admin.firestore().collection("users").doc(targetUserId).get();
    const userData = userDoc.data();
    const platform = userData?.platform || "android";

    // BASE DATA PAYLOAD
    const message = {
        token: callData.fcmToken,
        data: {
            type: "call",
            channelName: callData.channelName,
            callerId: callData.callerId,
            callerName: callData.callerName,
            callerAvatar: callData.callerAvatar || "",
        },
    };

    if (platform === "ios") {
        /**
         * 🛡️ iOS VOIP HARDENING (Phase 16)
         * CRITICAL: We DO NOT include a 'notification' block for iOS VoIP.
         * Pure data messages are required to trigger the native PKPushRegistry delegate
         * and allow CallKit to report the call WITHOUT the OS killing the app.
         */
        message.apns = {
            headers: {
                "apns-priority": "10",
                "apns-push-type": "voip",
                "apns-topic": "com.sachith.familytrack.ios.voip", // bundleID.voip
                "apns-expiration": "0", // Deliver immediately or drop
            },
            payload: {
                aps: {
                    "content-available": 1,
                    // Note: No 'alert' body here to ensure manual system UI handles it
                },
            },
        };
    } else {
        /**
         * 🤖 Android standard handling
         */
        message.notification = {
            title: "Incoming Voice Call",
            body: `${callData.callerName} is calling you...`,
        };
        message.android = {
            priority: "high",
            ttl: 0,
        };
    }

    try {
        const response = await admin.messaging().send(message);
        console.log(`✅ VoIP Signal sent to ${targetUserId} (${platform}):`, response);
        
        await snapshot.ref.update({
            pushSent: true,
            pushSentAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (error) {
        console.error("❌ VoIP Error:", error.message);
    }

    return null;
});
