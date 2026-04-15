const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");

admin.initializeApp();

// Set global options to match your database region
setGlobalOptions({ region: "asia-south1" });

/**
 * Cloud Function Phase 14: VoIP-Core Edition.
 * Handles cross-platform call signaling with specialized iOS PushKit support.
 */
exports.oncallcreated = onDocumentCreated("calls/{userId}", async (event) => {
    const snapshot = event.data;
    if (!snapshot) return null;

    const callData = snapshot.data();
    const targetUserId = event.params.userId;

    if (callData.status !== "ringing") return null;

    // Fetch target user metadata for platform-specific routing
    const userDoc = await admin.firestore().collection("users").doc(targetUserId).get();
    const userData = userDoc.data();
    const platform = userData?.platform || "android";

    const message = {
        token: callData.fcmToken,
        data: {
            type: "call",
            channelName: callData.channelName,
            callerId: callData.callerId,
            callerName: callData.callerName,
            callerAvatar: callData.callerAvatar || "",
            click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
        android: {
            priority: "high",
            ttl: 30000, // 30 seconds
        },
    };

    // Platform-Specific Routing
    if (platform === "ios") {
        message.apns = {
            headers: {
                "apns-priority": "10",
                "apns-push-type": "voip", // CRITICAL for PushKit wake-up
                "apns-topic": "com.sachith.familytrack.ios.voip",
                "apns-expiration": Math.floor(Date.now() / 1000) + 30,
            },
            payload: {
                aps: {
                    "content-available": 1,
                    "mutable-content": 1,
                    sound: "default",
                },
            },
        };
        // Clean notification block to ensure pure background data delivery to PushKit
        delete message.notification;
    } else {
        // Standard Android high-priority notification
        message.notification = {
            title: "Incoming Voice Call",
            body: `${callData.callerName} is calling you...`,
        };
    }

    try {
        const response = await admin.messaging().send(message);
        console.log(`✅ Signal sent to ${targetUserId} (${platform}):`, response);
        
        await snapshot.ref.update({
            pushSent: true,
            pushSentAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (error) {
        console.error("❌ Error sending wake-up signal:", error.message);
    }

    return null;
});
