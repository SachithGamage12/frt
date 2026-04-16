const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");

admin.initializeApp();

setGlobalOptions({ region: "us-central1" });

exports.sendCallNotification = onDocumentCreated("calls/{userId}", async (event) => {
    const data = event.data.data();
    if (!data) return;

    // Only send for 'ringing' status
    if (data.status !== 'ringing') return;

    const callPayload = {
        type: 'call',
        callerId: data.callerId || '',
        callerName: data.callerName || 'Family Member',
        callerAvatar: data.callerAvatar || '',
        channelName: data.channelName || '',
        priority: 'high',
    };

    // 🍏 iOS: Use FCM with content-available for background wake-up
    // Works with the .p8 Auth Key already in Firebase (no VoIP cert needed)
    if (data.platform === 'ios' && data.fcmToken) {
        console.log(`Sending FCM background call to iOS user: ${event.params.userId}`);
        const iosMessage = {
            token: data.fcmToken,
            data: callPayload,
            apns: {
                payload: {
                    aps: {
                        'content-available': 1,  // Wake app in background
                        'mutable-content': 1,
                        sound: 'default',
                        alert: {
                            title: `📞 ${callPayload.callerName} is calling`,
                            body: 'Tap to answer',
                        },
                    },
                    // Custom call data readable by Flutter
                    callData: callPayload,
                },
                headers: {
                    'apns-priority': '10',
                    'apns-push-type': 'alert',
                },
            },
        };
        try {
            await admin.messaging().send(iosMessage);
            console.log("✅ iOS FCM Call Signal Sent");
        } catch (error) {
            console.error("❌ iOS FCM Error:", error);
        }
    }

    // 🤖 Android: High-priority FCM data message
    if (data.fcmToken && data.platform !== 'ios') {
        console.log(`Sending FCM call to Android user: ${event.params.userId}`);
        const androidMessage = {
            token: data.fcmToken,
            data: callPayload,
            android: {
                priority: 'high',
                ttl: 0,
            },
        };
        try {
            await admin.messaging().send(androidMessage);
            console.log("✅ Android FCM Call Signal Sent");
        } catch (error) {
            console.error("❌ Android FCM Error:", error);
        }
    }
});
