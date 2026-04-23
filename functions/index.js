const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");

admin.initializeApp();

setGlobalOptions({ region: "us-central1" });

// 1. Send Notification on Account Approval
exports.onUserUpdated = onDocumentUpdated("users/{mobile}", async (event) => {
    const prevData = event.data.before.data();
    const newData = event.data.after.data();
    if (!prevData || !newData) return;

    // Detect Activation (isAppUnlocked changed false -> true)
    if (!prevData.isAppUnlocked && newData.isAppUnlocked) {
        const payload = {
            notification: {
                title: "✅ Account Activated!",
                body: "Your FRT account is now active for 1 month. You can open the app and login now. Thank you for choosing FRT!",
            },
            data: {
                click_action: "FLUTTER_NOTIFICATION_CLICK"
            }
        };

        const tokens = [];
        if (newData.fcmToken) tokens.push(newData.fcmToken);
        if (newData.webFcmToken) tokens.push(newData.webFcmToken);

        if (tokens.length > 0) {
            console.log(`Sending activation notification to ${newData.mobile}`);
            await admin.messaging().sendEachForMulticast({
                tokens: tokens,
                notification: payload.notification,
                data: payload.data
            });
        }
    }
});

// 2. Scheduled Expiry Warning (Runs daily at 9:00 AM)
exports.checkSubscriptionExpiry = onSchedule("0 9 * * *", async (event) => {
    const db = admin.firestore();
    const now = new Date();
    const threeDaysFromNow = new Date();
    threeDaysFromNow.setDate(now.getDate() + 3);

    // Query users whose subscription expires in the next 3 days and are still active
    const qSnap = await db.collection("users")
        .where("isAppUnlocked", "==", true)
        .where("subscriptionExpiry", ">", now)
        .where("subscriptionExpiry", "<=", threeDaysFromNow)
        .get();

    const jobs = [];
    qSnap.forEach(doc => {
        const u = doc.data();
        const tokens = [];
        if (u.fcmToken) tokens.push(u.fcmToken);
        if (u.webFcmToken) tokens.push(u.webFcmToken);

        if (tokens.length > 0) {
            jobs.push(admin.messaging().sendEachForMulticast({
                tokens: tokens,
                notification: {
                    title: "⚠️ Subscription Expiring Soon",
                    body: "Your FRT subscription will expire in 3 days. Please renew via the app to avoid interruption.",
                }
            }));
        }
    });

    await Promise.all(jobs);
    console.log(`Sent ${jobs.length} expiry warnings.`);
});

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
                    'apns-topic': 'com.sachith.familytrack.ios',
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
