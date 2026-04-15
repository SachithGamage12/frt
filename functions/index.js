const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");

admin.initializeApp();

// Set global options to match your database region
setGlobalOptions({ region: "asia-south1" });

/**
 * Cloud Function to handle incoming calls.
 * This has been hardened for iOS Background Wake-Up.
 */
exports.oncallcreated = onDocumentCreated("calls/{userId}", async (event) => {
    const snapshot = event.data;
    if (!snapshot) return null;

    const callData = snapshot.data();
    const targetUserId = event.params.userId;

    if (callData.status !== "ringing") return null;

    const message = {
        token: callData.fcmToken,
        notification: {
            title: "Incoming Voice Call",
            body: `${callData.callerName} is calling you...`,
        },
        data: {
            type: "call",
            channelName: callData.channelName,
            callerId: callData.callerId,
            callerName: callData.callerName,
            callerAvatar: callData.callerAvatar || "",
            // Add a click_action for extra reliability on legacy devices
            click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
        android: {
            priority: "high",
            ttl: 0,
        },
        apns: {
            headers: {
                "apns-priority": "10", // Crucial for immediate screen wake
                "apns-push-type": "alert",
                "apns-expiration": "0", // Deliver immediately or fail (don't queue)
            },
            payload: {
                aps: {
                    "content-available": 1, // Wake background isolate
                    "mutable-content": 1,   // Allow CallKit to intercept
                    sound: "default",
                    category: "incoming_call",
                },
            },
        },
    };

    try {
        await admin.messaging().send(message);
        console.log(`Successfully sent wake-up signal to ${targetUserId}`);
    } catch (error) {
        console.error("Error sending wake-up signal:", error);
    }

    return null;
});
