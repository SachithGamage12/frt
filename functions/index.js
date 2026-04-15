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

    const payload = {
        data: {
            type: 'call',
            callerId: data.callerId,
            callerName: data.callerName,
            callerAvatar: data.callerAvatar || '',
            channelName: data.channelName,
            priority: 'high',
        }
    };

    // 🍏 iOS VoIP Logic (Using PushKit)
    if (data.platform === 'ios' && data.voipToken) {
        console.log(`Sending VoIP Push to iOS user: ${event.params.userId}`);
        const voipMessage = {
            token: data.voipToken,
            data: payload.data, // For Android fallback if they use voipToken
            apns: {
                payload: {
                    aps: {
                        'content-available': 1,
                        priority: 10,
                    },
                    // Custom data for the Native AppDelegate to read
                    custom: payload.data
                },
                headers: {
                    'apns-priority': '10',
                    'apns-push-type': 'voip', // REQUIRED FOR IOS CALLS
                    'apns-topic': 'com.frt.frt.voip' // Bundle ID + .voip
                }
            }
        };
        try {
            await admin.messaging().send(voipMessage);
            console.log("✅ iOS VoIP Signal Sent");
        } catch (error) {
            console.error("❌ iOS VoIP Error:", error);
        }
    } 
    
    // 🤖 Android / Standard FCM Logic
    if (data.fcmToken) {
        console.log(`Sending Standard FCM to: ${event.params.userId}`);
        const fcmMessage = {
            token: data.fcmToken,
            data: payload.data,
            android: {
                priority: 'high',
                ttl: 0, // Instant
            }
        };
        try {
            await admin.messaging().send(fcmMessage);
            console.log("✅ Standard FCM Signal Sent");
        } catch (error) {
            console.error("❌ FCM Error:", error);
        }
    }
});
